-module(mnesia_store).
-behaviour(gen_server).

%%====================================================================
%% Mnesia_Store —— ETS 快照的磁盘中期存储 (gen_server 包装)
%%====================================================================
%%
%% 职责:
%%   - 启动时创建 mnesia schema + ets_snapshot 表 (disc_copies)
%%   - 提供同步 snapshot/restore API (供任意进程调用)
%%   - 周期性自动 snapshot 配置好的 ETS 表 (默认 60s 一次)
%%
%% 接入:
%%   作为 hermes_brains_sup 的第一个子进程启动 (rest_for_one 策略下,
%%   mnesia_store 崩溃会让 state_store 等后续子进程一起重启)。
%%   启动顺序: mnesia_store -> state_store -> bridge_manager -> agent_sup
%%
%% 配置 (hermes_brains env):
%%   mnesia_dir          —— mnesia 数据目录 (默认 "data/mnesia")
%%   snapshot_tables     —— 周期快照的 ETS 表名列表 (默认 [hermes_brains_state])
%%   snapshot_interval_ms —— 快照周期毫秒, 0 表示禁用定时器 (默认 60000)
%%
%% 用法:
%%   %% 主动单表快照 (随时可调):
%%   ok = mnesia_store:snapshot(hermes_brains_state),
%%   %% 主动单表恢复 (state_store init 已自动调用):
%%   ok = mnesia_store:restore(hermes_brains_state).
%%====================================================================

%% API
-export([start_link/0, init_store/0, snapshot/1, restore/1, stop/0]).
%% gen_server 回调
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("log.hrl").

-define(SERVER, ?MODULE).
-define(SNAPSHOT_TABLE, ets_snapshot).
-define(DEFAULT_INTERVAL_MS, 60_000).
-define(DEFAULT_SNAPSHOT_TABLES, [hermes_brains_state]).

-record(state, {
    snapshot_tables = [] :: [atom()],
    timer_ref = undefined :: reference() | undefined
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% 显式触发 schema + ets_snapshot 表创建 (gen_server init 已自动跑过, 一般无需调用)
init_store() ->
    gen_server:call(?SERVER, init_store, infinity).

%% 把指定 ETS 表当前内容全量快照到磁盘 (同步, 事务内 delete+write 替换)
-spec snapshot(atom()) -> ok | {error, term()}.
snapshot(EtsTab) when is_atom(EtsTab) ->
    gen_server:call(?SERVER, {snapshot, EtsTab}, infinity).

%% 把指定 ETS 表从磁盘快照恢复 (调用前 ETS 表必须已 ets:new 过)
-spec restore(atom()) -> ok | {error, term()}.
restore(EtsTab) when is_atom(EtsTab) ->
    gen_server:call(?SERVER, {restore, EtsTab}, infinity).

stop() ->
    gen_server:stop(?SERVER).

%%%===================================================================
%%% gen_server 回调
%%%===================================================================

init([]) ->
    %% 启动时同步初始化 mnesia schema + snapshot 表 (失败让 supervisor 重启)
    case do_init_store() of
        ok ->
            Tables = application:get_env(hermes_brains, snapshot_tables,
                                         ?DEFAULT_SNAPSHOT_TABLES),
            Interval = snapshot_interval_ms(),
            TimerRef = case Interval of
                0 ->
                    ?log("mnesia_store started, periodic snapshot DISABLED, tables=~p",
                         [Tables]),
                    undefined;
                _ ->
                    ?log("mnesia_store started, snapshot_tables=~p, interval_ms=~p",
                         [Tables, Interval]),
                    schedule_snapshot(Interval)
            end,
            {ok, #state{snapshot_tables = Tables, timer_ref = TimerRef}};
        {error, _} = Err ->
            ?log_error("mnesia_store init failed: ~p, stopping", [Err]),
            {stop, Err}
    end.

handle_call(init_store, _From, State) ->
    {reply, do_init_store(), State};

handle_call({snapshot, EtsTab}, _From, State) ->
    {reply, do_snapshot(EtsTab), State};

handle_call({restore, EtsTab}, _From, State) ->
    {reply, do_restore(EtsTab), State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% 周期快照触发: 把所有配置的表都 dump 一遍, 然后重新调度下一次
handle_info({snapshot_tick}, State) ->
    lists:foreach(fun(Tab) -> do_snapshot(Tab) end, State#state.snapshot_tables),
    Interval = snapshot_interval_ms(),
    NewTimer = case Interval of
        0 -> undefined;
        _ -> schedule_snapshot(Interval)
    end,
    {noreply, State#state{timer_ref = NewTimer}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

snapshot_interval_ms() ->
    application:get_env(hermes_brains, snapshot_interval_ms, ?DEFAULT_INTERVAL_MS).

schedule_snapshot(Interval) ->
    erlang:send_after(Interval, self(), {snapshot_tick}).

%% 同步初始化 mnesia schema + ets_snapshot 表 (幂等)
do_init_store() ->
    Dir = application:get_env(hermes_brains, mnesia_dir, "data/mnesia"),
    ok = filelib:ensure_dir(Dir ++ "/"),
    ok = application:set_env(mnesia, dir, Dir),
    Node = node(),
    %% 创建磁盘 schema (mnesia 未运行时才能建; 已存在则忽略)
    case mnesia:create_schema([Node]) of
        ok ->
            ?log("mnesia schema created at ~s", [Dir]);
        {error, {_, {already_exists, _}}} ->
            ?log_trace("mnesia schema already exists at ~s", [Dir]);
        {error, Reason1} ->
            ?log_error("mnesia create_schema failed: ~p", [Reason1]),
            error({mnesia_schema_failed, Reason1})
    end,
    %% 启动 mnesia 应用 (作为 .app.src 的 applications 依赖本应已起来, 这里幂等保证)
    case application:ensure_started(mnesia) of
        ok -> ok;
        {error, {already_started, mnesia}} -> ok;
        {error, Reason2} ->
            ?log_error("mnesia start failed: ~p", [Reason2]),
            error({mnesia_start_failed, Reason2})
    end,
    %% 创建 ets_snapshot 表 (disc_copies = 落盘)
    case mnesia:create_table(?SNAPSHOT_TABLE, [
        {attributes, [table_name, data]},
        {disc_copies, [Node]}
    ]) of
        {atomic, ok} ->
            ?log("mnesia snapshot table created (disc_copies)"),
            ok;
        {aborted, {already_exists, _}} ->
            ?log_trace("mnesia snapshot table already exists"),
            ok;
        {aborted, Reason3} ->
            ?log_error("mnesia create_table failed: ~p", [Reason3]),
            error({mnesia_create_table_failed, Reason3})
    end.

%% 把 ETS 表全量快照到 mnesia (事务内 delete + write, 等价全量替换)
do_snapshot(EtsTab) when is_atom(EtsTab) ->
    try ets:tab2list(EtsTab) of
        Data ->
            case mnesia:transaction(fun() ->
                mnesia:write_lock_table(?SNAPSHOT_TABLE),
                mnesia:delete({?SNAPSHOT_TABLE, EtsTab}),
                mnesia:write(?SNAPSHOT_TABLE, {?SNAPSHOT_TABLE, EtsTab, Data}, write)
            end) of
                {atomic, ok} ->
                    ?log("snapshot taken, table=~p, entries=~p",
                         [EtsTab, length(Data)]),
                    ok;
                {aborted, Reason} ->
                    ?log_error("snapshot failed, table=~p, reason=~p",
                               [EtsTab, Reason]),
                    {error, Reason}
            end
    catch
        error:badarg ->
            ?log_warning("snapshot: ets table ~p does not exist", [EtsTab]),
            {error, no_such_ets}
    end.

%% 从 mnesia 读快照, ets:insert 回 ETS (调用前 ETS 必须已 ets:new 过)
do_restore(EtsTab) when is_atom(EtsTab) ->
    {atomic, Result} = mnesia:transaction(fun() ->
        mnesia:read(?SNAPSHOT_TABLE, EtsTab)
    end),
    case Result of
        [{?SNAPSHOT_TABLE, EtsTab, Data}] when is_list(Data) ->
            try
                lists:foreach(fun(Entry) -> ets:insert(EtsTab, Entry) end, Data),
                ?log("restore ok, table=~p, entries=~p",
                     [EtsTab, length(Data)]),
                ok
            catch
                error:badarg ->
                    ?log_error("restore: ets table ~p does not exist", [EtsTab]),
                    {error, no_such_ets}
            end;
        [] ->
            ?log_warning("restore: no snapshot for table=~p", [EtsTab]),
            {error, no_snapshot}
    end.
