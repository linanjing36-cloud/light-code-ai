-module(approval_store).
-behaviour(gen_server).

%%====================================================================
%% Approval_Store —— 高风险能力调用的审批请求注册表 (EXEC-P0-005)
%%====================================================================
%%
%% 职责:
%%   - 维护 req_id -> 审批等待条目的映射 (ETS, named, public)
%%   - 提供 register / lookup / resolve / list_pending / cancel 接口
%%   - 自动过期: register 时启动定时器, 超时后置为 expired 并通知 FSM
%%
%% 设计要点:
%%   - 写操作走 gen_server:call 串行化, 读操作直接 ets:lookup (public 表)
%%   - 不持有会话真相: 仅记录"谁在等审批", 不决定"是否允许"
%%   - resolve/2 原子地把 pending -> approved/rejected, 返回 entry 供
%%     panel_server cast 唤醒对应 FSM
%%   - 作为顶层监督者子进程 (state_store 之后), 崩溃随 rest_for_one 重启
%%
%% 状态机 (entry.status):
%%   pending  -> approved  (用户允许)
%%   pending  -> rejected  (用户拒绝)
%%   pending  -> expired   (超时)
%%   pending  -> canceled  (FSM 主动取消, 如会话结束)
%%====================================================================

%% 对外接口
-export([start_link/0,
         register/4, lookup/1, resolve/2,
         list_pending/0, list_by_session/1,
         cancel/1, delete/1]).
%% gen_server 回调
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TABLE, hermes_approvals).
-define(EXPIRE_MS, 300000). %% 5 分钟自动过期

-record(entry, {req_id     :: binary(),
                fsm_pid    :: pid(),
                session_id :: binary(),
                tool_call  :: map(),
                registered_at :: integer(),
                status :: pending | approved | rejected | expired | canceled}).
-record(state, {}).

%%%===================================================================
%%% 对外接口
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% register(ReqId, FsmPid, SessionId, ToolCall) -> ok | {error, already_exists}
%%
%% 注册一个等待审批的 tool_call。ReqId 由调用方 (agent_fsm) 生成, 与
%% ToolExecRequest.req_id 一致, 是 approve RPC 的幂等键。
register(ReqId, FsmPid, SessionId, ToolCall) when is_binary(ReqId), is_map(ToolCall) ->
    gen_server:call(?MODULE, {register, ReqId, FsmPid, SessionId, ToolCall}).

%% lookup(ReqId) -> {ok, Entry} | not_found
%%
%% Entry 为 map: #{req_id, fsm_pid, session_id, tool_call, registered_at, status}
lookup(ReqId) when is_binary(ReqId) ->
    case ets:lookup(?TABLE, ReqId) of
        [#entry{} = E] -> {ok, entry_to_map(E)};
        [] -> not_found
    end.

%% resolve(ReqId, Allow) -> {ok, Entry} | not_found | {error, not_pending}
%%
%% 用户审批结果回填。Allow=true -> approved, false -> rejected。
%% 仅 pending 状态可 resolve, 否则返回 {error, not_pending}。
%% 返回 entry 供 panel_server cast 唤醒对应 FSM。
resolve(ReqId, Allow) when is_binary(ReqId), is_boolean(Allow) ->
    gen_server:call(?MODULE, {resolve, ReqId, Allow}).

%% list_pending() -> [Entry]
%%
%% 返回所有 pending 状态的审批条目 (供观测/审计)。
list_pending() ->
    [entry_to_map(E) || E <- ets:tab2list(?TABLE),
                        E#entry.status =:= pending].

%% list_by_session(SessionId) -> [Entry]
list_by_session(SessionId) when is_binary(SessionId) ->
    [entry_to_map(E) || E <- ets:tab2list(?TABLE),
                        E#entry.session_id =:= SessionId].

%% cancel(ReqId) -> ok
%%
%% FSM 主动取消 (如会话结束、循环上限触发)。幂等。
cancel(ReqId) when is_binary(ReqId) ->
    gen_server:call(?MODULE, {cancel, ReqId}).

%% delete(ReqId) -> ok
%%
%% 彻底删除条目 (清理用)。幂等。
delete(ReqId) when is_binary(ReqId) ->
    gen_server:call(?MODULE, {delete, ReqId}).

%%%===================================================================
%%% gen_server 回调
%%%===================================================================

init([]) ->
    %% 测试或重启场景: 旧表可能残留, 先清理再建
    try ets:delete(?TABLE) catch _:_ -> ok end,
    ets:new(?TABLE, [named_table, set, public,
                     {keypos, #entry.req_id},
                     {read_concurrency, true}]),
    {ok, #state{}}.

handle_call({register, ReqId, FsmPid, SessionId, ToolCall}, _From, State) ->
    case ets:lookup(?TABLE, ReqId) of
        [#entry{status = pending}] ->
            {reply, {error, already_exists}, State};
        _ ->
            %% 旧条目 (已 resolved/expired/canceled) 允许覆盖注册新轮次
            Now = erlang:system_time(millisecond),
            TimerRef = erlang:send_after(?EXPIRE_MS, self(), {expire, ReqId}),
            Entry = #entry{req_id = ReqId,
                           fsm_pid = FsmPid,
                           session_id = SessionId,
                           tool_call = ToolCall,
                           registered_at = Now,
                           status = pending},
            ets:insert(?TABLE, Entry),
            %% TimerRef 存到 entry 里以便 cancel 时取消定时器
            ets:insert(?TABLE, Entry#entry{tool_call = maps:put(<<"_expire_timer">>, TimerRef, ToolCall)}),
            {reply, ok, State}
    end;

handle_call({resolve, ReqId, Allow}, _From, State) ->
    case ets:lookup(?TABLE, ReqId) of
        [#entry{status = pending} = E] ->
            NewStatus = case Allow of true -> approved; false -> rejected end,
            cancel_expire_timer(E),
            ets:insert(?TABLE, E#entry{status = NewStatus}),
            {reply, {ok, entry_to_map(E#entry{status = NewStatus})}, State};
        [#entry{}] ->
            {reply, {error, not_pending}, State};
        [] ->
            {reply, not_found, State}
    end;

handle_call({cancel, ReqId}, _From, State) ->
    case ets:lookup(?TABLE, ReqId) of
        [#entry{status = pending} = E] ->
            cancel_expire_timer(E),
            ets:insert(?TABLE, E#entry{status = canceled}),
            {reply, ok, State};
        _ ->
            {reply, ok, State}
    end;

handle_call({delete, ReqId}, _From, State) ->
    case ets:lookup(?TABLE, ReqId) of
        [#entry{} = E] ->
            cancel_expire_timer(E),
            ets:delete(?TABLE, ReqId);
        [] ->
            ok
    end,
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({expire, ReqId}, State) ->
    case ets:lookup(?TABLE, ReqId) of
        [#entry{status = pending} = E] ->
            ets:insert(?TABLE, E#entry{status = expired}),
            %% 通知 FSM 该 req_id 已过期 (FSM 收到后回填 error observation)
            try erlang:send(E#entry.fsm_pid, {approval_expired, ReqId}) catch _:_ -> ok end,
            {noreply, State};
        _ ->
            %% 已 resolved/canceled/deleted, 忽略过期消息
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% 内部函数
%%%===================================================================

entry_to_map(#entry{req_id = ReqId, fsm_pid = Pid, session_id = Sid,
                    tool_call = ToolCall, registered_at = At, status = Status}) ->
    %% tool_call 里可能存了 _expire_timer, 对外暴露时去掉
    CleanToolCall = maps:remove(<<"_expire_timer">>, ToolCall),
    #{req_id => ReqId,
      fsm_pid => Pid,
      session_id => Sid,
      tool_call => CleanToolCall,
      registered_at => At,
      status => Status}.

cancel_expire_timer(#entry{tool_call = ToolCall}) ->
    case maps:get(<<"_expire_timer">>, ToolCall, undefined) of
        undefined -> ok;
        TimerRef -> erlang:cancel_timer(TimerRef), ok
    end.
