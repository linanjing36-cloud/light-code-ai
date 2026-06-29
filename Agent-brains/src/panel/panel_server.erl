-module(panel_server).
-behaviour(gen_server).

%%====================================================================
%% Panel_Server —— Hermes 面板与 Erlang 大脑之间的 Protobuf 桥 (TCP)
%%====================================================================
%%
%% 架构定位 (新架构: 三进程独立启动 + 连接池):
%%   Wails (Go)  ──TCP 连接池──▶  panel_server (本模块, Erlang)
%%                                     │
%%                                     ▼
%%                                agent_fsm (ReAct 编排)
%%                                     │
%%                                     ▼ (bridge_manager: TCP 连接池)
%%                                Eion-tools (Go)
%%
%% 协议 (Task 2 改造: JSON-RPC → Protobuf):
%%   - 帧格式: 4 字节大端长度 + PanelFrame 的 Protobuf 二进制
%%   - 顶层帧: PanelFrame{ oneof payload { PanelRequest request; PanelResponse response; PanelStream stream; } }
%%   - 请求: {request, Id, Method, ArgsMap}  (Id 用于响应路由匹配)
%%   - 响应: {response, Id, ok, ResultMap} | {response, Id, error, ErrMsg}
%%   - 流式 push: {stream, StreamId, {chunk|tool_event|final|error, Map}}
%%     (在 send 方法的原连接上连续推, 直到 final/error 终态)
%%   - connection handler: {active, once} multiplex tcp / push_stream / rpc_reply
%%     dispatch 在 spawn 中执行, 不阻塞读循环与流式 push
%%
%% 流式输出 (Task 4):
%%   - send 方法注册 session_id -> {stream_id, conn_pid} 到 ETS panel_streams
%%   - agent_fsm 在 thinking 收到 LLM chunk 时 cast 给本 server: {push_chunk, SessionId, ChunkMap}
%%   - 本 server 查 ETS 找 ConnPid, 给 ConnPid 发 {push_stream, FrameBin}
%%   - connection 进程在 receive 循环中处理 {push_stream, FrameBin} -> gen_tcp:send
%%   - final/error 终态后从 ETS 删除该 session 的 stream 注册
%%
%% 启动流程 (独立启动模式):
%%   1. 在 127.0.0.1 上 listen 一个 ephemeral port (port 0)
%%   2. 把完整地址 "127.0.0.1:<port>" 写入端口文件 (供 Wails 读取发现)
%%      同时仍向 stdout 打印 "PANEL_PORT:<port>" 行 (兼容旧脚本/调试)
%%   3. spawn 一个 acceptor 进程, 每个连接再 spawn 一个 connection 进程
%%
%% 端口文件路径解析 (优先级):
%%   1. app env panel_addr_file
%%   2. 环境变量 PANEL_ADDR_FILE
%%   3. 默认 "panel.addr"
%%
%% 支持的方法 (与 Go 侧 brain.Bridge.Call / HermesService 对齐):
%%   start_session   [{system_prompt}]              -> {ok, #{session_id => binary()}}
%%   send            [{session_id, message}]        -> {ok, #{stream_id => binary()}}
%%   list_tools      []                              -> {ok, #{tools => [...]}}
%%   list_pending_approvals []                       -> {ok, #{approvals => [...]}}
%%   get_history     [{session_id}]                  -> {ok, #{messages => [...]}}
%%   approve         [{req_id, allow}]               -> {ok, #{ok => true}}
%%   brain_status    [{session_id}]                 -> {ok, #{state, loop_count, ...}}
%%   delete_session  [{session_id}]                 -> {ok, #{ok => true}}
%%   stop            []                              -> 触发 init:stop() 优雅退出

-include("log.hrl").

-export([start_link/0, serve/0, exec_agent/2,
         %% 流式 push API (供 agent_fsm cast)
         push_chunk/2, push_tool_event/2, push_final/2, push_stream_err/2,
         push_approval_required/2, push_plan_generated/2, push_plan_step_update/2,
         unregister_stream/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(STREAMS_TABLE, panel_streams).
-define(EXEC_TIMEOUT_PAD, 5000).

-record(exec_pending, {
    from :: gen_server:from(),
    conn_pid :: pid(),
    acc = [] :: [binary()],
    timer_ref :: reference()
}).

-record(wails_conn, {
    pid :: pid(),
    busy = false :: boolean()
}).

-record(state, {
    listen_socket :: gen_tcp:socket(),
    port :: inet:port_number(),
    wails_conns = [] :: [#wails_conn{}],
    exec_seq = 0 :: non_neg_integer(),
    exec_pending = #{} :: #{non_neg_integer() => #exec_pending{}}
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

serve() ->
    case panel_server:start_link() of
        {ok, _Pid} -> ok;
        {error, _} = Err -> Err
    end.

%% ---- 流式 push API (agent_fsm cast 调用, 异步转发到对应连接) ----

push_chunk(SessionId, ChunkMap) ->
    gen_server:cast(?MODULE, {push_chunk, SessionId, ChunkMap}).

push_tool_event(SessionId, EvMap) ->
    gen_server:cast(?MODULE, {push_tool_event, SessionId, EvMap}).

push_final(SessionId, FinalMap) ->
    gen_server:cast(?MODULE, {push_final, SessionId, FinalMap}).

push_stream_err(SessionId, ErrMsg) ->
    gen_server:cast(?MODULE, {push_stream_err, SessionId, ErrMsg}).

%% 审批请求推送 (EXEC-P0-005): 告知前端某 tool_call 需用户授权。
%% ApprovalMap: #{req_id, session_id, tool_call_id, tool_name, arguments_json, risk_level, expire_ms}
push_approval_required(SessionId, ApprovalMap) ->
    gen_server:cast(?MODULE, {push_approval_required, SessionId, ApprovalMap}).

%% 计划生成推送 (EXEC-P2-001): Planner 生成执行计划后推送给前端
push_plan_generated(SessionId, PlanMap) ->
    gen_server:cast(?MODULE, {push_plan_generated, SessionId, PlanMap}).

%% 计划步骤更新推送 (EXEC-P2-001): 工具执行时更新步骤状态
push_plan_step_update(SessionId, UpdateMap) ->
    gen_server:cast(?MODULE, {push_plan_step_update, SessionId, UpdateMap}).

%% session 结束或 client 断开时清理 stream 注册
unregister_stream(SessionId) ->
    gen_server:cast(?MODULE, {unregister_stream, SessionId}).

%% Phase B: bridge_manager 经 panel 连接让 Wails 进程内执行 hermes AgentRequest。
%% Payload = pb_codec:encode_req/1 产物; 返回 {ok, [RespBin,...]} | {error, Reason}
exec_agent(Payload, TimeoutMs) when is_binary(Payload), is_integer(TimeoutMs), TimeoutMs > 0 ->
    gen_server:call(?MODULE, {exec_agent, Payload, TimeoutMs}, TimeoutMs + ?EXEC_TIMEOUT_PAD).

%%====================================================================
%% gen_server 回调
%%====================================================================

init([]) ->
    %% 流式路由表: session_id -> {stream_id, conn_pid}
    %% public + named_table: 让 connection 进程也能 ets:insert
    ets:new(?STREAMS_TABLE, [set, named_table, public, {read_concurrency, true}]),
    Opts = [
        {active, false},
        {mode, binary},
        {packet, 0},
        {reuseaddr, true},
        {ip, {127, 0, 0, 1}}
    ],
    case gen_tcp:listen(0, Opts) of
        {ok, Sock} ->
            {ok, Port} = inet:port(Sock),
            Addr = io_lib:format("127.0.0.1:~p", [Port]),
            case write_addr_file(Addr) of
                ok -> ?log("panel addr file written: ~s (~s)", [panel_addr_file(), Addr]);
                {error, WErr} -> ?log_warning("write panel addr file failed: ~p (addr=~s)", [WErr, Addr])
            end,
            io:format("PANEL_PORT:~p~n", [Port]),
            Acceptor = spawn(fun() -> accept_loop(Sock) end),
            erlang:link(Acceptor),
            {ok, #state{listen_socket = Sock, port = Port}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call({exec_agent, Payload, TimeoutMs}, From, State) ->
    case pick_idle_wails_conn(State#state.wails_conns) of
        {ok, ConnPid, Conns1} ->
            Id = State#state.exec_seq + 1,
            TRef = erlang:start_timer(TimeoutMs, self(), {exec_timeout, Id}),
            Pending = #exec_pending{from = From, conn_pid = ConnPid,
                                    timer_ref = TRef},
            Frame = panel_pb_codec:pack_exec(Id, Payload),
            ConnPid ! {push_stream, Frame},
            State1 = State#state{
                wails_conns = mark_wails_busy(Conns1, ConnPid, true),
                exec_seq = Id,
                exec_pending = maps:put(Id, Pending, State#state.exec_pending)
            },
            {noreply, State1};
        none ->
            {reply, {error, no_wails_conn}, State}
    end;
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% ---- 流式 push: 查 ETS 找 ConnPid, 给 ConnPid 发 {push_stream, FrameBin} ----
handle_cast({push_chunk, SessionId, ChunkMap}, State) ->
    forward_stream(SessionId, fun(StreamId) ->
        panel_pb_codec:pack_stream_chunk(StreamId, ChunkMap)
    end),
    {noreply, State};
handle_cast({push_tool_event, SessionId, EvMap}, State) ->
    forward_stream(SessionId, fun(StreamId) ->
        panel_pb_codec:pack_stream_tool_event(StreamId, EvMap)
    end),
    {noreply, State};
handle_cast({push_final, SessionId, FinalMap}, State) ->
    %% final 是终态: push 后清理 stream 注册
    forward_stream(SessionId, fun(StreamId) ->
        panel_pb_codec:pack_stream_final(StreamId, FinalMap)
    end),
    ets:delete(?STREAMS_TABLE, SessionId),
    {noreply, State};
handle_cast({push_stream_err, SessionId, ErrMsg}, State) ->
    %% error 是终态: push 后清理 stream 注册
    forward_stream(SessionId, fun(StreamId) ->
        panel_pb_codec:pack_stream_err(StreamId, ErrMsg)
    end),
    ets:delete(?STREAMS_TABLE, SessionId),
    {noreply, State};
handle_cast({push_approval_required, SessionId, ApprovalMap}, State) ->
    %% 审批请求 (非终态): 不清理 stream 注册, FSM 等待 approve RPC 唤醒
    forward_stream(SessionId, fun(StreamId) ->
        panel_pb_codec:pack_stream_approval_required(StreamId, ApprovalMap)
    end),
    {noreply, State};
handle_cast({push_plan_generated, SessionId, PlanMap}, State) ->
    forward_stream(SessionId, fun(StreamId) ->
        panel_pb_codec:pack_stream_plan_generated(StreamId, PlanMap)
    end),
    {noreply, State};
handle_cast({push_plan_step_update, SessionId, UpdateMap}, State) ->
    forward_stream(SessionId, fun(StreamId) ->
        panel_pb_codec:pack_stream_plan_step_update(StreamId, UpdateMap)
    end),
    {noreply, State};
handle_cast({unregister_stream, SessionId}, State) ->
    ets:delete(?STREAMS_TABLE, SessionId),
    {noreply, State};
handle_cast({register_wails_conn, ConnPid}, State) ->
    Conns = State#state.wails_conns,
    case lists:any(fun(#wails_conn{pid = P}) -> P =:= ConnPid end, Conns) of
        true ->
            {noreply, State};
        false ->
            ?log("wails conn registered: pid=~p total=~p", [ConnPid, length(Conns) + 1]),
            {noreply, State#state{wails_conns = Conns ++ [#wails_conn{pid = ConnPid}]}}
    end;
handle_cast({unregister_wails_conn, ConnPid}, State) ->
    Conns = lists:filter(fun(#wails_conn{pid = P}) -> P =/= ConnPid end,
                         State#state.wails_conns),
    {noreply, State#state{wails_conns = Conns}};
handle_cast({exec_result, ConnPid, Id, AgentRespBin, Err, Terminal}, State) ->
    {noreply, handle_exec_result(ConnPid, Id, AgentRespBin, Err, Terminal, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({timeout, TRef, {exec_timeout, Id}}, State) ->
    case maps:get(Id, State#state.exec_pending, undefined) of
        #exec_pending{from = From, conn_pid = ConnPid, timer_ref = StoredTRef}
          when StoredTRef =:= TRef ->
            gen_server:reply(From, {error, timeout}),
            Conns = mark_wails_busy(State#state.wails_conns, ConnPid, false),
            {noreply, State#state{
                wails_conns = Conns,
                exec_pending = maps:remove(Id, State#state.exec_pending)
            }};
        _ ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{listen_socket = Sock}) ->
    try gen_tcp:close(Sock) catch _:_ -> ok end,
    _ = file:delete(panel_addr_file()),
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% 内部: 流式转发到对应 connection 进程
%%====================================================================

%% 查 ETS 找 ConnPid, 给 ConnPid 发 {push_stream, FrameBin}
%% 若 session 无活跃 stream (client 断开或未注册), 静默丢弃
forward_stream(SessionId, EncodeFun) ->
    case ets:lookup(?STREAMS_TABLE, SessionId) of
        [{SessionId, StreamId, ConnPid}] when is_pid(ConnPid) ->
            case is_process_alive(ConnPid) of
                true ->
                    FrameBin = EncodeFun(StreamId),
                    ConnPid ! {push_stream, FrameBin};
                false ->
                    %% connection 进程已死, 清理残留注册
                    ets:delete(?STREAMS_TABLE, SessionId)
            end;
        _ ->
            ok
    end.

%%====================================================================
%% 内部: acceptor loop (单独进程, 持续 accept 新连接)
%%====================================================================

accept_loop(Sock) ->
    case gen_tcp:accept(Sock) of
        {ok, Conn} ->
            Remote = format_remote(Conn),
            ?log("connection accepted: remote=~s", [Remote]),
            %% 继续 accept; 本连接交给独立 handler (controlling_process 同步返回 ok 后交付)
            spawn(fun() -> accept_loop(Sock) end),
            Handler = spawn_link(fun() ->
                receive {start, S, R} -> connection_recv_loop(S, R) end
            end),
            case gen_tcp:controlling_process(Conn, Handler) of
                ok ->
                    Handler ! {start, Conn, Remote};
                {error, Err} ->
                    ?log_error("controlling_process failed remote=~s: ~p", [Remote, Err]),
                    unlink(Handler),
                    exit(Handler, shutdown),
                    ok
            end;
        {error, closed} ->
            ?log("accept loop exiting: listen socket closed", []);
        {error, Reason} ->
            ?log_warning("accept failed: ~p", [Reason]),
            ok
    end.

%%====================================================================
%% 内部: connection receive loop (每连接一个进程, active once)
%%   - {packet, 4}: {tcp, Sock, Bin} 为一帧 Protobuf 负载
%%   - push_stream 走 mailbox, 与 tcp 在同一 receive 中 multiplex
%%====================================================================

connection_recv_loop(Sock, Remote) ->
    ok = inet:setopts(Sock, [{packet, 4}, {active, once}]),
    gen_server:cast(?MODULE, {register_wails_conn, self()}),
    ?log("connection handler ready: remote=~s pid=~p", [Remote, self()]),
    connection_active_loop(Sock, Remote).

connection_active_loop(Sock, Remote) ->
    ok = inet:setopts(Sock, [{active, once}]),
    receive
        {push_stream, FrameBin} ->
            send_frame(Sock, FrameBin),
            connection_active_loop(Sock, Remote);
        {rpc_reply, FrameBin} ->
            send_frame(Sock, FrameBin),
            connection_active_loop(Sock, Remote);
        {tcp, Sock, Bin} ->
            handle_client_frame(Sock, Remote, Bin),
            connection_active_loop(Sock, Remote);
        {tcp_closed, Sock} ->
            ?log("connection handler exiting: remote=~s closed by peer", [Remote]),
            gen_server:cast(?MODULE, {unregister_wails_conn, self()}),
            cleanup_streams_for_self(),
            ok;
        {tcp_error, Sock, Reason} ->
            ?log_warning("connection handler exiting: remote=~s tcp_error=~p", [Remote, Reason]),
            gen_server:cast(?MODULE, {unregister_wails_conn, self()}),
            cleanup_streams_for_self(),
            ok
    end.

handle_client_frame(_Sock, Remote, Bin) ->
    case panel_pb_codec:unpack_frame(Bin) of
        {request, Id, Method, ArgsMap} ->
            ?log("request received: remote=~s id=~p method=~s", [Remote, Id, Method]),
            ConnPid = self(),
            spawn(fun() ->
                MethodBin = ensure_method_binary(Method),
                {RespTag, RespData} = dispatch(Id, MethodBin, ArgsMap, ConnPid),
                Frame = case RespTag of
                    ok -> panel_pb_codec:pack_response_ok(Id, MethodBin, RespData);
                    error -> panel_pb_codec:pack_response_err(Id, RespData)
                end,
                ConnPid ! {rpc_reply, Frame}
            end);
        {exec_result, Id, AgentRespBin, Err, Terminal} ->
            gen_server:cast(?MODULE, {exec_result, self(), Id, AgentRespBin, Err, Terminal});
        Other ->
            ?log_warning("invalid frame from remote=~s: ~p", [Remote, Other])
    end.

ensure_method_binary(M) when is_binary(M) -> M;
ensure_method_binary(M) when is_list(M) -> list_to_binary(M);
ensure_method_binary(M) when is_atom(M) -> atom_to_binary(M, utf8);
ensure_method_binary(M) -> iolist_to_binary(io_lib:format("~p", [M])).

%% 发送一帧: {packet, 4} 模式下 gen_tcp 自动加 4 字节大端长度前缀, 此处只发 Protobuf 负载
send_frame(Sock, FrameBin) ->
    gen_tcp:send(Sock, FrameBin).

%% connection 进程退出前清理以 self() 为 ConnPid 的 stream 注册 (防止 ETS 残留)
cleanup_streams_for_self() ->
    Self = self(),
    ets:foldl(fun({SessionId, _StreamId, ConnPid}, ok) when ConnPid =:= Self ->
                  ets:delete(?STREAMS_TABLE, SessionId);
                 (_, ok) -> ok
              end, ok, ?STREAMS_TABLE).

%%====================================================================
%% 调度: Id + Method + ArgsMap -> {ok, ResultMap} | {error, ErrMsg}
%%====================================================================

dispatch(_Id, Method, ArgsMap, ConnPid) ->
    try handle_method(Method, ArgsMap, ConnPid)
    catch
        Class:Reason:Stack ->
            ?log_error("dispatch method=~s failed: ~p:~p~n~p", [Method, Class, Reason, Stack]),
            ErrMsg = erlang:iolist_to_binary(io_lib:format("~p:~p", [Class, Reason])),
            {error, ErrMsg}
    end.

%% ---- start_session: 派发一个 agent_fsm 进程 ----
handle_method(<<"start_session">>, ArgsMap, _ConnPid) ->
    SystemPrompt = maps:get(system_prompt, ArgsMap, <<>>),
    Model = case maps:get(model, ArgsMap, <<>>) of
                <<>> -> application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>);
                M -> M
            end,
    ApiKey = maps:get(api_key, ArgsMap, <<>>),
    ApiBase = case maps:get(api_base, ArgsMap, <<>>) of
                  <<>> -> application:get_env(hermes_brains, api_base, <<>>);
                  B -> B
              end,
    SessionId = generate_session_id(),
    FSMArgs = [{session_id, SessionId},
               {model, Model},
               %% 会话启动时直接注入统一 capability 描述。
               %% 后续在 agent_fsm/thinking(enter) 中再做基于上下文的裁剪，
               %% 保证真正暴露给模型的是 Erlang 侧筛过的一致能力集。
               {tools, panel_tools:fetch_capability_descs()},
               {session_prompt, SystemPrompt},
               {api_key, ApiKey},
               {api_base, ApiBase},
               {history, []}],
    case agent_sup:start_agent(FSMArgs) of
        {ok, Pid} ->
            ok = state_store:register_session(SessionId, Pid),
            ?log("session started: id=~p pid=~p", [SessionId, Pid]),
            {ok, #{session_id => SessionId}};
        {error, Reason} ->
            ErrMsg = erlang:iolist_to_binary(io_lib:format("start_agent_failed: ~p", [Reason])),
            {error, ErrMsg}
    end;

%% ---- send: 触发 ReAct 循环, 注册 stream ----
handle_method(<<"send">>, ArgsMap, ConnPid) ->
    SessionId = maps:get(session_id, ArgsMap),
    Message = maps:get(message, ArgsMap),
    case state_store:lookup_session(SessionId) of
        {ok, Pid} ->
            UserMsg = #{role => <<"user">>, content => Message},
            ok = state_store:append_history(SessionId, UserMsg),
            %% 注册 stream: session_id -> {stream_id, conn_pid}
            %% ConnPid 为 connection handler (dispatch 在 spawn 中执行, 不能用 self())
            StreamId = generate_stream_id(),
            ets:insert(?STREAMS_TABLE, {SessionId, StreamId, ConnPid}),
            %% 先注册 stream，再触发 ReAct，避免极快返回时 final 在注册前被静默丢弃。
            agent_fsm:start(Pid, #{}),
            {ok, #{stream_id => StreamId}};
        not_found ->
            ErrMsg = erlang:iolist_to_binary(io_lib:format("session_not_found: ~s", [SessionId])),
            {error, ErrMsg}
    end;

%% ---- list_tools: 从 Eion-tools 动态同步工具注册表 ----
handle_method(<<"list_tools">>, _ArgsMap, _ConnPid) ->
    {ok, #{tools => panel_tools:fetch_tool_descs()}};

%% ---- list_capabilities: 统一能力目录（首版先把 tool 映射为 capability） ----
handle_method(<<"list_capabilities">>, _ArgsMap, _ConnPid) ->
    {ok, #{capabilities => panel_tools:fetch_capability_descs()}};

%% ---- list_pending_approvals: 审批中心拉取全局待审批队列 ----
handle_method(<<"list_pending_approvals">>, _ArgsMap, _ConnPid) ->
    RiskIndex = capability_risk_index(),
    Pending0 = [approval_entry_to_pending_pb(E, RiskIndex) || E <- approval_store:list_pending()],
    Pending = lists:sort(
                fun(A, B) ->
                    maps:get(registered_at, A, 0) =< maps:get(registered_at, B, 0)
                end,
                Pending0),
    {ok, #{approvals => Pending}};

%% ---- debug_capability: 面板直调单个 capability，供能力市场/调试面板使用 ----
handle_method(<<"debug_capability">>, ArgsMap, _ConnPid) ->
    Name = maps:get(capability_name, ArgsMap, <<>>),
    ArgsJson = maps:get(arguments_json, ArgsMap, <<>>),
    TimeoutMs = maps:get(timeout_ms, ArgsMap, 5000),
    ReqId = iolist_to_binary(
              ["debug-", Name, "-", integer_to_binary(erlang:unique_integer([positive]))]),
    ToolReq = #{id => ReqId, name => Name, arguments => ArgsJson},
    case bridge_manager:call_tool_sync(ToolReq, TimeoutMs) of
        {ok, Resp} ->
            {ok, #{capability_name => Name,
                   result_json => maps:get(result_json, Resp, <<>>),
                   error => maps:get(error, Resp, <<>>)}};
        {error, Reason} ->
            {ok, #{capability_name => Name,
                   result_json => <<>>,
                   error => iolist_to_binary(io_lib:format("~p", [Reason]))}}
    end;

%% ---- get_history: 读 state_store 短期记忆 ----
handle_method(<<"get_history">>, ArgsMap, _ConnPid) ->
    SessionId = maps:get(session_id, ArgsMap, <<>>),
    case state_store:get_history(SessionId) of
        {ok, Msgs} ->
            {ok, #{messages => Msgs}};
        {error, _} ->
            {ok, #{messages => []}}
    end;

%% ---- approve: 工具调用授权 (EXEC-P0-005) ----
%% 解码 {req_id, allow} -> approval_store:resolve -> cast 唤醒 FSM。
%% 返回结构化结果: #{ok, state, req_id} 供前端判断审批状态。
handle_method(<<"approve">>, ArgsMap, _ConnPid) ->
    ReqId = maps:get(req_id, ArgsMap, <<>>),
    Allow = maps:get(allow, ArgsMap, false),
    case ReqId of
        <<>> ->
            {ok, #{ok => false, error => <<"missing req_id">>, state => <<"invalid">>}};
        _ ->
            case approval_store:resolve(ReqId, Allow) of
                {ok, Entry} ->
                    %% cast 唤醒等待中的 FSM (FSM 收到 {approval, ReqId, Allow} 后继续派发或回填 error)
                    FsmPid = maps:get(fsm_pid, Entry, undefined),
                    case FsmPid of
                        undefined -> ok;
                        Pid when is_pid(Pid) ->
                            try erlang:send(Pid, {approval, ReqId, Allow}) catch _:_ -> ok end
                    end,
                    State = case maps:get(status, Entry) of
                                approved -> <<"approved">>;
                                rejected -> <<"rejected">>
                            end,
                    {ok, #{ok => true, req_id => ReqId, state => State}};
                not_found ->
                    {ok, #{ok => false, req_id => ReqId, error => <<"not_found">>, state => <<"not_found">>}};
                {error, not_pending} ->
                    {ok, #{ok => false, req_id => ReqId, error => <<"not_pending">>, state => <<"already_resolved">>}}
            end
    end;

%% ---- brain_status: 读 FSM 当前状态 ----
handle_method(<<"brain_status">>, ArgsMap, _ConnPid) ->
    SessionId = maps:get(session_id, ArgsMap, <<>>),
    case state_store:get_status(SessionId) of
        {ok, Status} ->
            {ok, Status};
        not_found ->
            {ok, #{state => <<"not_found">>}}
    end;

%% ---- delete_session: 终止 FSM + 清理 state_store / 摘要 / 向量记忆 ----
handle_method(<<"delete_session">>, ArgsMap, _ConnPid) ->
    SessionId = maps:get(session_id, ArgsMap),
    ok = panel_server:unregister_stream(SessionId),
    ok = memory_summarizer:purge_session(SessionId),
    ok = memory_tier:purge_session(SessionId),
    purge_vector_memory(SessionId),
    case state_store:lookup_session(SessionId) of
        {ok, Pid} ->
            _ = agent_sup:stop_agent(Pid),
            ok;
        not_found ->
            ok
    end,
    ok = state_store:delete_session(SessionId),
    ?log("session deleted: id=~p", [SessionId]),
    {ok, #{ok => true}};

%% ---- Provider 配置中心 (EXEC-P2-003) ----

handle_method(<<"list_providers">>, _ArgsMap, _ConnPid) ->
    Providers = provider_store:list_providers(),
    {ok, #{providers => Providers}};

handle_method(<<"upsert_provider">>, ArgsMap, _ConnPid) ->
    Provider = maps:get(provider, ArgsMap, #{}),
    case provider_store:upsert_provider(Provider) of
        ok ->
            {ok, #{ok => true, id => maps:get(id, Provider, <<>>)}};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end;

handle_method(<<"delete_provider">>, ArgsMap, _ConnPid) ->
    Id = maps:get(provider_id, ArgsMap, <<>>),
    case provider_store:delete_provider(Id) of
        ok ->
            {ok, #{ok => true}};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end;

handle_method(<<"set_default_provider">>, ArgsMap, _ConnPid) ->
    Id = maps:get(provider_id, ArgsMap, <<>>),
    case provider_store:set_default_provider(Id) of
        ok ->
            {ok, #{ok => true}};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end;

handle_method(<<"test_provider">>, _ArgsMap, _ConnPid) ->
    %% Provider 连通性测试: 简单返回成功 (后续可接入真实LLM ping)
    {ok, #{ok => true, latency_ms => 0, error => <<>>}};

handle_method(<<"get_risk_policies">>, _ArgsMap, _ConnPid) ->
    case mnesia:transaction(fun() ->
        mnesia:match_object(risk_policies, {risk_policies, '_', '_'}, read)
    end) of
        {atomic, Rows} ->
            Policies = [#{risk_level => L, action => A}
                        || {risk_policies, L, A} <- Rows],
            {ok, #{policies => Policies}};
        _ ->
            {ok, #{policies => [
                #{risk_level => <<"safe">>, action => <<"allow">>},
                #{risk_level => <<"review">>, action => <<"approve">>},
                #{risk_level => <<"dangerous">>, action => <<"deny">>}
            ]}}
    end;

handle_method(<<"set_risk_policy">>, ArgsMap, _ConnPid) ->
    Level = maps:get(risk_level, ArgsMap, <<>>),
    Action = maps:get(action, ArgsMap, <<>>),
    case provider_store:set_risk_policy(Level, Action) of
        ok ->
            {ok, #{ok => true}};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end;

handle_method(<<"set_session_provider">>, ArgsMap, _ConnPid) ->
    SessionId = maps:get(session_id, ArgsMap, <<>>),
    ProviderId = maps:get(provider_id, ArgsMap, <<>>),
    case provider_store:set_session_provider(SessionId, ProviderId) of
        ok ->
            {ok, #{ok => true}};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end;

%% ---- 记忆管理 RPC (EXEC-P2-002) ----

handle_method(<<"list_memories">>, ArgsMap, _ConnPid) ->
    SessionId = maps:get(session_id, ArgsMap, <<"global">>),
    TierBin = maps:get(tier, ArgsMap, <<"unspecified">>),
    Tier = case TierBin of
               <<"facts">> -> facts;
               <<"preferences">> -> preferences;
               <<"workspace">> -> workspace;
               _ -> all
           end,
    Memories = case Tier of
                   all ->
                       All = memory_tier:get_all(SessionId),
                       lists:append([mem_to_pb_list(T, Ms) || {T, Ms} <- maps:to_list(All)]);
                   T ->
                       Ms = memory_tier:get_tier(SessionId, T),
                       mem_to_pb_list(T, Ms)
               end,
    {ok, #{memories => Memories}};

handle_method(<<"add_memory">>, ArgsMap, _ConnPid) ->
    SessionId0 = maps:get(session_id, ArgsMap, <<"global">>),
    SessionId = case SessionId0 of
                    <<>> -> <<"global">>;
                    S -> S
                end,
    TierBin = maps:get(tier, ArgsMap, <<"facts">>),
    Tier = case TierBin of
               <<"preferences">> -> preferences;
               <<"workspace">> -> workspace;
               _ -> facts
           end,
    Content = maps:get(content, ArgsMap, <<>>),
    case memory_tier:put(SessionId, Tier, Content, <<"manual">>) of
        ok ->
            Key = make_memory_key(Content),
            {ok, #{ok => true, key => Key}};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end;

handle_method(<<"delete_memory">>, ArgsMap, _ConnPid) ->
    SessionId0 = maps:get(session_id, ArgsMap, <<"global">>),
    SessionId = case SessionId0 of
                    <<>> -> <<"global">>;
                    S -> S
                end,
    TierBin = maps:get(tier, ArgsMap, <<"facts">>),
    Tier = case TierBin of
               <<"preferences">> -> preferences;
               <<"workspace">> -> workspace;
               _ -> facts
           end,
    Key = maps:get(key, ArgsMap, <<>>),
    case memory_tier:delete(SessionId, Tier, Key) of
        ok ->
            {ok, #{ok => true}};
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end;

handle_method(<<"clear_memories">>, ArgsMap, _ConnPid) ->
    SessionId0 = maps:get(session_id, ArgsMap, <<"global">>),
    SessionId = case SessionId0 of
                    <<>> -> <<"global">>;
                    S -> S
                end,
    TierBin = maps:get(tier, ArgsMap, <<"unspecified">>),
    Count = case TierBin of
                <<"facts">> ->
                    clear_tier_memories(SessionId, facts);
                <<"preferences">> ->
                    clear_tier_memories(SessionId, preferences);
                <<"workspace">> ->
                    clear_tier_memories(SessionId, workspace);
                _ ->
                    C1 = clear_tier_memories(SessionId, facts),
                    C2 = clear_tier_memories(SessionId, preferences),
                    C3 = clear_tier_memories(SessionId, workspace),
                    C1 + C2 + C3
            end,
    {ok, #{ok => true, count => Count}};

%% ---- 取消执行 (EXEC-P2-001) ----

handle_method(<<"cancel_execution">>, ArgsMap, _ConnPid) ->
    SessionId = maps:get(session_id, ArgsMap, <<>>),
    case state_store:lookup_session(SessionId) of
        {ok, Pid} ->
            try erlang:send(Pid, {cancel_execution}) of
                _ -> {ok, #{ok => true}}
            catch
                _:_ -> {ok, #{ok => false}}
            end;
        not_found ->
            {ok, #{ok => false}}
    end;

%% ---- stop: 优雅退出整个 erl 节点 ----
handle_method(<<"stop">>, _ArgsMap, _ConnPid) ->
    spawn(fun() -> timer:sleep(100), init:stop() end),
    {ok, #{ok => true}};

%% ---- 兜底 ----
handle_method(Method, _ArgsMap, _ConnPid) ->
    ErrMsg = erlang:iolist_to_binary(io_lib:format("unknown_method: ~s", [Method])),
    {error, ErrMsg}.

capability_risk_index() ->
    maps:from_list(
      [{maps:get(name, Cap, <<>>), maps:get(risk_level, Cap, <<"dangerous">>)}
       || Cap <- panel_tools:fetch_capability_descs(),
          is_map(Cap)]).

approval_entry_to_pending_pb(Entry, RiskIndex) ->
    ToolCall = maps:get(tool_call, Entry, #{}),
    ToolName = maps:get(name, ToolCall, <<>>),
    #{
      req_id => maps:get(req_id, Entry, <<>>),
      session_id => maps:get(session_id, Entry, <<>>),
      tool_call_id => maps:get(id, ToolCall, maps:get(req_id, Entry, <<>>)),
      tool_name => ToolName,
      arguments_json => tool_call_arguments_json(ToolCall),
      risk_level => maps:get(ToolName, RiskIndex, <<"dangerous">>),
      expire_ms => 300000,
      registered_at => maps:get(registered_at, Entry, 0)
     }.

tool_call_arguments_json(ToolCall) ->
    case maps:get(arguments, ToolCall, <<>>) of
        Bin when is_binary(Bin) ->
            Bin;
        List when is_list(List) ->
            unicode:characters_to_binary(List);
        undefined ->
            <<>>;
        Term ->
            try json:encode(Term)
            catch
                _:_ -> iolist_to_binary(io_lib:format("~p", [Term]))
            end
    end.

%%====================================================================
%% 内部: id 生成
%%====================================================================

generate_session_id() ->
    Ts = integer_to_binary(erlang:system_time(millisecond)),
    Rand = integer_to_binary(rand:uniform(999999)),
    <<"sess-", Ts/binary, "-", Rand/binary>>.

generate_stream_id() ->
    Ts = integer_to_binary(erlang:system_time(millisecond)),
    Rand = integer_to_binary(rand:uniform(999999)),
    <<"stream-", Ts/binary, "-", Rand/binary>>.

%% 经 Eion-tools memory_purge_session 工具清除 Redis/向量库中该 session 的记忆 (best-effort)
purge_vector_memory(SessionId) ->
    ReqId = iolist_to_binary(["purge-", integer_to_list(erlang:unique_integer([positive]))]),
    SessBin = ensure_session_id_binary(SessionId),
    ArgsJson = iolist_to_binary(
        ["{\"session_id\":\"", json_escape_binary(SessBin), "\"}"]),
    Tool = #{id => ReqId, name => <<"memory_purge_session">>, arguments => ArgsJson},
    case bridge_manager:call_tool_sync(Tool, 15000) of
        {ok, _Resp} ->
            ok;
        {error, Reason} ->
            ?log_warning("purge_vector_memory session=~p failed: ~p", [SessionId, Reason]),
            ok
    end.

ensure_session_id_binary(S) when is_binary(S) -> S;
ensure_session_id_binary(S) when is_list(S) -> list_to_binary(S);
ensure_session_id_binary(S) when is_atom(S) -> atom_to_binary(S, utf8);
ensure_session_id_binary(S) -> iolist_to_binary(io_lib:format("~p", [S])).

json_escape_binary(Bin) when is_binary(Bin) ->
    lists:flatten([json_escape_char(C) || <<C>> <= Bin]).

json_escape_char($") -> "\\\"";
json_escape_char($\\) -> "\\\\";
json_escape_char(C) when C >= 32, C =< 126 -> [C];
json_escape_char(C) -> "\\u" ++ io_lib:format("~4..0B", [C]).

%%====================================================================
%% 内部: 端口文件 (地址发现)
%%====================================================================

panel_addr_file() ->
    case application:get_env(hermes_brains, panel_addr_file) of
        {ok, F} when is_list(F), F =/= "" -> F;
        _ ->
            case os:getenv("PANEL_ADDR_FILE") of
                false -> "panel.addr";
                "" -> "panel.addr";
                F -> F
            end
    end.

write_addr_file(Addr) when is_list(Addr); is_binary(Addr) ->
    file:write_file(panel_addr_file(), Addr).

format_remote(Sock) ->
    case inet:peername(Sock) of
        {ok, {{A, B, C, D}, Port}} ->
            lists:flatten(io_lib:format("~p.~p.~p.~p:~p", [A, B, C, D, Port]));
        {error, _} ->
            "unknown"
    end.

%%====================================================================
%% 内部: Phase B exec (Wails 连接池 + exec_result 聚合)
%%====================================================================

pick_idle_wails_conn(Conns) ->
    pick_idle_wails_conn(Conns, []).

pick_idle_wails_conn([], _Acc) ->
    none;
pick_idle_wails_conn([#wails_conn{pid = Pid, busy = false} = C | Rest], Acc) ->
    case is_process_alive(Pid) of
        true ->
            {ok, Pid, lists:reverse(Acc) ++ [C | Rest]};
        false ->
            pick_idle_wails_conn(Rest, Acc)
    end;
pick_idle_wails_conn([C | Rest], Acc) ->
    pick_idle_wails_conn(Rest, [C | Acc]).

mark_wails_busy(Conns, ConnPid, Busy) ->
    [case C#wails_conn.pid of
         ConnPid -> C#wails_conn{busy = Busy};
         _ -> C
     end || C <- Conns].

handle_exec_result(ConnPid, Id, AgentRespBin, Err, Terminal, State) ->
    case maps:get(Id, State#state.exec_pending, undefined) of
        #exec_pending{from = From, acc = Acc, timer_ref = TRef} = P
          when P#exec_pending.conn_pid =:= ConnPid ->
            case Err of
                E when E =/= <<>> ->
                    _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
                    gen_server:reply(From, {error, Err}),
                    finish_exec(ConnPid, Id, State);
                _ ->
                    Acc1 = Acc ++ [AgentRespBin],
                    case Terminal of
                        true ->
                            _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
                            gen_server:reply(From, {ok, Acc1}),
                            finish_exec(ConnPid, Id, State);
                        false ->
                            State#state{exec_pending = maps:put(Id, P#exec_pending{acc = Acc1},
                                                               State#state.exec_pending)}
                    end
            end;
        _ ->
            State
    end.

finish_exec(ConnPid, Id, State) ->
    State#state{
        wails_conns = mark_wails_busy(State#state.wails_conns, ConnPid, false),
        exec_pending = maps:remove(Id, State#state.exec_pending)
    }.

%%====================================================================
%% 内部: Memory RPC 辅助
%%====================================================================

mem_to_pb_list(Tier, Items) ->
    TierBin = tier_to_bin(Tier),
    [#{key => maps:get(key, I, <<>>),
       tier => TierBin,
       content => maps:get(content, I, <<>>),
       source => maps:get(source, I, <<"auto">>),
       created_at => maps:get(ts, I, 0),
       session_id => <<"global">>} || I <- Items].

tier_to_bin(facts) -> <<"facts">>;
tier_to_bin(preferences) -> <<"preferences">>;
tier_to_bin(workspace) -> <<"workspace">>;
tier_to_bin(_) -> <<"facts">>.

make_memory_key(Content) when is_binary(Content) ->
    <<Hash:160, _/binary>> = crypto:hash(sha, Content),
    iolist_to_binary(io_lib:format("~40.16.0b", [Hash])).

clear_tier_memories(SessionId, Tier) ->
    Items = memory_tier:get_tier(SessionId, Tier),
    lists:foreach(fun(I) ->
        Key = maps:get(key, I, <<>>),
        case Key of
            <<>> -> ok;
            _ -> memory_tier:delete(SessionId, Tier, Key)
        end
    end, Items),
    length(Items).
