-module(case_store).
-behaviour(gen_server).

%%====================================================================
%% Case_Store —— 失败案例库 (负面案例记忆)
%%====================================================================
%%
%% 职责:
%%   - 持有 Mnesia disc_copies 表 failure_cases, 跨重启持久化
%%   - record/1: agent_fsm 在失败点 (工具失败/循环耗尽/LLM错误/断连) 写入一条案例
%%   - query/1: thinking 前查最近 N 条相关案例, 经 context_assembler 注入 System Prompt
%%
%% 设计意图:
%%   "失败重启"不够 —— 重启会丢经验。把每次失败固化成结构化案例,
%%   下次 LLM 在 thinking 前看到"之前这样试过, 失败原因是 X", 少踩坑。
%%
%% 表结构 (Mnesia, record_name = failure_cases):
%%   {failure_cases, case_id, ts, data}
%%     case_id : binary() 主键 (<<"case-", ts, "-", rand>>)
%%     ts      : integer() 毫秒时间戳 (排序用)
%%     data    : map() 完整案例
%%               #{session_id, tool_name, scenario, attempted, failure_reason, lesson}
%%
%% 容量上限: ?MAX_CASES (默认 200), 超过淘汰最老的, 防止无限膨胀。
%% 200 条规模全表扫 + 代码过滤足够, 不建二级索引 (避免过度设计)。
%%
%% 依赖: mnesia_store 必须先启动 (本模块 init 调 mnesia:create_table,
%%       要求 mnesia app 已运行)。sup 中置于末尾, 崩溃仅自重启,
%%       不影响 agent_fsm (FSM 查询走防御性匹配 {error,_} -> 跳过注入)。
%%====================================================================

%% 对外接口
-export([start_link/0, record/1, query/1, query/2, clear/0, count/0]).
%% gen_server 回调
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("log.hrl").

-define(SERVER, ?MODULE).
-define(TABLE, failure_cases).
-define(MAX_CASES, 200).
-define(DEFAULT_QUERY_LIMIT, 5).

-record(state, {}).

%%%===================================================================
%%% 对外接口
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% 写入一条失败案例。
%% CaseMap 必填: scenario, failure_reason
%% 可选:   session_id, tool_name, attempted, lesson
%% case_id / ts 由本函数自动填充。
-spec record(map()) -> ok | {error, term()}.
record(CaseMap) when is_map(CaseMap) ->
    gen_server:call(?SERVER, {record, CaseMap}, infinity).

%% 查询最近 N 条案例 (默认 5, 按 ts 倒序)。
%% Opts:
%%   tool_name => binary() | undefined | <<>>  按工具名过滤 (undefined/<<>> = 全部)
%%   limit     => pos_integer()                 返回条数上限
-spec query(map()) -> {ok, [map()]} | {error, term()}.
query(Opts) when is_map(Opts) ->
    gen_server:call(?SERVER, {query, Opts}, infinity).

%% 便捷查询: 按工具名查最近 N 条 (ToolName = undefined | <<>> 表示不过滤)
-spec query(binary() | undefined, pos_integer()) -> {ok, [map()]} | {error, term()}.
query(ToolName, Limit) when is_integer(Limit), Limit > 0 ->
    query(#{tool_name => ToolName, limit => Limit}).

%% 清空所有案例 (调试/测试用)
-spec clear() -> ok | {error, term()}.
clear() ->
    gen_server:call(?SERVER, clear, infinity).

%% 当前案例总数
-spec count() -> non_neg_integer().
count() ->
    gen_server:call(?SERVER, count, infinity).

%%%===================================================================
%%% gen_server 回调
%%%===================================================================

init([]) ->
    case create_table() of
        ok ->
            ?log("case_store started, table=~p, max_cases=~p", [?TABLE, ?MAX_CASES]),
            {ok, #state{}};
        {error, _Reason} = Err ->
            ?log_error("case_store init failed: ~p", [Err]),
            {stop, Err}
    end.

handle_call({record, CaseMap}, _From, State) ->
    {reply, do_record(CaseMap), State};
handle_call({query, Opts}, _From, State) ->
    {reply, do_query(Opts), State};
handle_call(clear, _From, State) ->
    {reply, do_clear(), State};
handle_call(count, _From, State) ->
    {reply, do_count(), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% 内部函数
%%%===================================================================

%% 创建 failure_cases 表 (幂等)。要求 mnesia app 已由 mnesia_store 启动。
create_table() ->
    Node = node(),
    case mnesia:create_table(?TABLE, [
        {attributes, [case_id, ts, data]},
        {disc_copies, [Node]}
    ]) of
        {atomic, ok} ->
            ?log("case_store table created (disc_copies): ~p", [?TABLE]),
            ok;
        {aborted, {already_exists, _}} ->
            ?log_trace("case_store table already exists: ~p", [?TABLE]),
            ok;
        {aborted, Reason} ->
            ?log_error("case_store create_table failed: ~p", [Reason]),
            {error, {create_table_failed, Reason}}
    end.

%% 生成 case_id
new_case_id(Ts) ->
    Rand = rand:uniform(999999),
    <<"case-", (integer_to_binary(Ts))/binary, "-",
      (integer_to_binary(Rand))/binary>>.

%% 写入案例 + 容量管控 (超过 MAX_CASES 淘汰最老)
do_record(CaseIn) ->
    Ts = erlang:system_time(millisecond),
    CaseId = new_case_id(Ts),
    Data = CaseIn#{
        case_id => CaseId,
        ts => Ts,
        session_id => maps:get(session_id, CaseIn, <<>>),
        tool_name => maps:get(tool_name, CaseIn, <<>>),
        scenario => maps:get(scenario, CaseIn, <<>>),
        attempted => maps:get(attempted, CaseIn, <<>>),
        failure_reason => maps:get(failure_reason, CaseIn, <<>>),
        lesson => maps:get(lesson, CaseIn, <<>>)
    },
    case mnesia:transaction(fun() ->
        mnesia:write(?TABLE, {?TABLE, CaseId, Ts, Data}, write)
    end) of
        {atomic, ok} ->
            ?log("failure case recorded: id=~s scenario=~s tool=~s",
                 [CaseId, maps:get(scenario, Data, <<>>),
                  maps:get(tool_name, Data, <<>>)]),
            %% 容量管控 (best-effort, 失败仅记日志不阻断)
            _ = maybe_evict(),
            ok;
        {aborted, Reason} ->
            ?log_error("case_store record failed: ~p", [Reason]),
            {error, Reason}
    end.

%% 查询: 全表扫 -> 按 tool_name 过滤 -> 按 ts 倒序 -> 截断 limit
do_query(Opts) ->
    ToolName = maps:get(tool_name, Opts, undefined),
    Limit = maps:get(limit, Opts, ?DEFAULT_QUERY_LIMIT),
    case mnesia:transaction(fun() ->
        %% match_object with all '_' returns all rows
        mnesia:match_object(?TABLE, {?TABLE, '_', '_', '_'}, read)
    end) of
        {atomic, Rows} ->
            Cases = [Data || {?TABLE, _Id, _Ts, Data} <- Rows],
            Filtered = case ToolName of
                undefined -> Cases;
                <<>> -> Cases;
                TN -> [C || C <- Cases,
                            maps:get(tool_name, C, <<>>) =:= TN]
            end,
            Sorted = lists:sort(fun(A, B) ->
                maps:get(ts, A, 0) >= maps:get(ts, B, 0)
            end, Filtered),
            {ok, lists:sublist(Sorted, Limit)};
        {aborted, Reason} ->
            ?log_error("case_store query failed: ~p", [Reason]),
            {error, Reason}
    end.

do_clear() ->
    case mnesia:transaction(fun() -> mnesia:clear_table(?TABLE) end) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

do_count() ->
    case mnesia:transaction(fun() -> mnesia:table_info(?TABLE, size) end) of
        {atomic, N} when is_integer(N) -> N;
        _ -> 0
    end.

%% 容量管控: 超过 MAX_CASES 时淘汰最老的 (N - MAX) 条
maybe_evict() ->
    case mnesia:transaction(fun() ->
        N = mnesia:table_info(?TABLE, size),
        case N > ?MAX_CASES of
            true ->
                Rows = mnesia:match_object(?TABLE, {?TABLE, '_', '_', '_'}, read),
                %% 升序 (老 -> 新), 取前面多余的删掉
                Sorted = lists:sort(fun({_, _, TsA, _}, {_, _, TsB, _}) ->
                    TsA < TsB
                end, Rows),
                Excess = N - ?MAX_CASES,
                Oldest = lists:sublist(Sorted, Excess),
                lists:foreach(fun({?TABLE, Id, _, _}) ->
                    mnesia:delete(?TABLE, Id, write)
                end, Oldest),
                {ok, Excess};
            false ->
                ok
        end
    end) of
        {atomic, {ok, Excess}} ->
            ?log("case_store evicted ~p oldest cases (cap=~p)", [Excess, ?MAX_CASES]),
            ok;
        {atomic, ok} ->
            ok;
        {aborted, Reason} ->
            ?log_warning("case_store evict failed (non-fatal): ~p", [Reason]),
            {error, Reason}
    end.
