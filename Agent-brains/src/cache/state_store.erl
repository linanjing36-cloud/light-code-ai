-module(state_store).
-behaviour(gen_server).

%%====================================================================
%% State_Store —— 系统级 ETS 持有者 (快照 + 短期记忆)
%%====================================================================
%%
%% 职责:
%%   - 持有 ETS 表 (named, public, read_concurrency), 供 FSM 读写
%%   - 存放 FSM 快照 (session_id => #data{}), 用于崩溃恢复
%%   - 存放按会话分组的短期记忆 (session_id => [Message])
%%
%% 作为顶层监督者的子进程, 其崩溃会触发 rest_for_one 重启 (ETS 随之重建)。
%%====================================================================

%% 对外接口
-export([start_link/0,
         put_snapshot/2, get_snapshot/1,
         put_status/2, get_status/1,
         append_history/2, get_history/1,
         register_session/2, lookup_session/1, unregister_session/1,
         delete_session/1]).
%% gen_server 回调
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TABLE, hermes_brains_state).

-record(state, {}).

%%%===================================================================
%%% 对外接口
%%%===================================================================

start_link() ->
    cache:init_table_config(),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% 落 FSM 快照 (崩溃恢复用)
put_snapshot(SessionId, Data) ->
    ets:insert(?TABLE, {{snapshot, SessionId}, Data}),
    ok.

get_snapshot(SessionId) ->
    lookup_snapshot(SessionId).

%% 追加短期记忆 (按会话): 维护一个倒序表, 读取时反转为正序
append_history(SessionId, Message) ->
    gen_server:call(?MODULE, {append_history, SessionId, Message}).

get_history(SessionId) ->
    lookup_history(SessionId).

%% 轻量状态快照: 供 panel_server/前端轮询读取, 避免走 sys:get_state/2
put_status(SessionId, StatusMap) ->
    ets:insert(?TABLE, {{status, SessionId}, StatusMap}),
    ok.

get_status(SessionId) ->
    case ets:lookup(?TABLE, {status, SessionId}) of
        [{{status, SessionId}, StatusMap}] -> {ok, StatusMap};
        [] -> not_found
    end.

%% 会话注册: SessionId -> agent_fsm Pid (由 panel_server 在 start_session 时写入)
%% 用于 panel_server 在 send/brain_status 时反查 FSM 进程。
register_session(SessionId, Pid) ->
    ets:insert(?TABLE, {{session_pid, SessionId}, Pid}),
    ok.

lookup_session(SessionId) ->
    case lookup_session_once(SessionId) of
        {ok, _} = Ok ->
            Ok;
        not_found ->
            %% transient 重启窗口: 旧 pid 已死, 新 FSM 可能尚未 register
            timer:sleep(200),
            lookup_session_once(SessionId)
    end.

lookup_session_once(SessionId) ->
    case ets:lookup(?TABLE, {session_pid, SessionId}) of
        [{{session_pid, SessionId}, Pid}] ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false ->
                    ets:delete(?TABLE, {session_pid, SessionId}),
                    not_found
            end;
        [] ->
            not_found
    end.

unregister_session(SessionId) ->
    ets:delete(?TABLE, {session_pid, SessionId}),
    ok.

%% 删除会话全部 ETS 状态 (history / snapshot / session_pid)
delete_session(SessionId) ->
    ets:delete(?TABLE, {session_pid, SessionId}),
    ets:delete(?TABLE, {history, SessionId}),
    ets:delete(?TABLE, {snapshot, SessionId}),
    ets:delete(?TABLE, {status, SessionId}),
    ok.

lookup_snapshot(SessionId) ->
    case ets:lookup(?TABLE, {snapshot, SessionId}) of
        [{{snapshot, SessionId}, Data}] -> {ok, Data};
        [] -> not_found
    end.

lookup_history(SessionId) ->
    case ets:lookup(?TABLE, {history, SessionId}) of
        [{{history, SessionId}, Msgs}] -> {ok, lists:reverse(Msgs)};
        [] -> {ok, []}
    end.

%%%===================================================================
%%% gen_server 回调
%%%===================================================================

init([]) ->
    %% named_table: 让 FSM/其他进程可并发读; 复合写(如 append_history)仍经本 GenServer 串行化
    ets:new(?TABLE, [set, public, named_table, {read_concurrency, true}]),
    %% 从磁盘快照恢复 ETS 内容 (mnesia_store 已在 sup 中先行启动)
    %% 第一次启动没有快照, mnesia_store:restore 返回 {error, no_snapshot}, 这里只记录不阻塞
    case mnesia_store:restore(?TABLE) of
        ok ->
            lager:info("state_store: ETS ~p restored from mnesia snapshot",
                       [?TABLE]);
        {error, no_snapshot} ->
            lager:info("state_store: no mnesia snapshot for ~p, starting fresh",
                       [?TABLE]);
        {error, Reason} ->
            lager:warning("state_store: restore ~p failed: ~p, starting fresh",
                          [?TABLE, Reason])
    end,
    {ok, #state{}}.

handle_call({put_snapshot, SessionId, Data}, _From, State) ->
    ets:insert(?TABLE, {{snapshot, SessionId}, Data}),
    {reply, ok, State};
handle_call({get_snapshot, SessionId}, _From, State) ->
    {reply, lookup_snapshot(SessionId), State};
handle_call({append_history, SessionId, Message}, _From, State) ->
    Current = case ets:lookup(?TABLE, {history, SessionId}) of
                  [{{history, SessionId}, Msgs}] -> Msgs;
                  [] -> []
              end,
    %% 头插 (O(1)); 读取时反转
    ets:insert(?TABLE, {{history, SessionId}, [Message | Current]}),
    {reply, ok, State};
handle_call({get_history, SessionId}, _From, State) ->
    {reply, lookup_history(SessionId), State};
handle_call({register_session, SessionId, Pid}, _From, State) ->
    ets:insert(?TABLE, {{session_pid, SessionId}, Pid}),
    {reply, ok, State};
handle_call({unregister_session, SessionId}, _From, State) ->
    ets:delete(?TABLE, {session_pid, SessionId}),
    {reply, ok, State};
handle_call({delete_session, SessionId}, _From, State) ->
    ets:delete(?TABLE, {session_pid, SessionId}),
    ets:delete(?TABLE, {history, SessionId}),
    ets:delete(?TABLE, {snapshot, SessionId}),
    ets:delete(?TABLE, {status, SessionId}),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
