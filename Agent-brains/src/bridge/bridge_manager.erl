-module(bridge_manager).
-behaviour(gen_server).

%%====================================================================
%% Bridge_Manager —— Go 侧 Eion-tools 连接管理器 (TCP 连接池模式)
%%====================================================================
%%
%% 架构变更: 从 open_port spawn 子进程改为 TCP 连接池连接独立运行的
%% Eion-tools server。Eion-tools 现在是独立进程, listen TCP(Windows)/
%% UDS(Unix), 本模块作为客户端建立连接池。
%%
%% 职责:
%%   - init 时建立 N 个 gen_tcp 连接到 Eion-tools server (连接池)
%%   - 维护 FIFO 请求队列: 业务请求经 pb_codec 编码为 Protobuf 二进制后排队
%%   - 连接池分发: 取 idle 连接发请求, 收到响应后连接回 idle, 发下一条
%%   - 监听 {tcp, Socket, Bin} 响应, 解码后按 Ref 投回对应 FSM
%%   - 超时管理: 单次原子请求超时即失败上报
%%   - 连接断开: 通知等待中的 FSM, 异步重连
%%
%% 接口语义: 全部异步 (cast)。返回 Ref 供 FSM 匹配响应。
%%   call_llm(FsmPid, Req)          -> Ref          响应回投 {llm_response, Ref, Resp}
%%   call_tool_batch(FsmPid, TCs)   -> ok           每条响应回投 {tool_result, ToolCallId, Resp}
%%
%% 凭证处理: api_base / api_key 由本进程从 app env 注入, 不进入 FSM 状态。
%%
%% 帧格式 (与 Eion-tools cmd/server/main.go 对齐):
%%   4 字节大端长度前缀 + protobuf 负载
%%   gen_tcp {packet, 4} 自动处理 4 字节长度前缀
%%
%% 地址发现 (优先级):
%%   1. app env eion_tools_addr (直接地址, 如 "127.0.0.1:12345")
%%   2. app env eion_tools_addr_file (端口文件路径, 读文件取地址)
%%   3. 默认 "127.0.0.1:7891"
%%====================================================================

%% 对外接口
-export([start_link/0, call_llm/2, call_tool_batch/2, call_tool/2, call_tool_sync/2,
         list_tools/1, pool_info/0]).
%% gen_server 回调
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(LLM_TIMEOUT, 60000).        %% 单次 LLM 推理超时 (v4-pro 推理模型可能较慢)
-define(TOOL_TIMEOUT, 15000).       %% 单次工具执行超时
-define(DEFAULT_POOL_SIZE, 4).      %% 连接池大小
-define(RECONNECT_DELAY, 2000).     %% 重连间隔 (ms)
-define(DEFAULT_ADDR, "127.0.0.1:7891").

-record(conn, {
    socket :: gen_tcp:socket() | undefined,
    state :: idle | busy
}).

-record(state, {
    addr :: string(),
    pool_size :: pos_integer(),
    conns = [] :: [#conn{}],
    %% FIFO 队列: 等待 idle 连接的请求
    %%   {Ref, FsmPid, Kind, ReqId, Payload, Timeout}
    queue = queue:new() :: queue:queue({reference(), pid() | undefined, llm | tool | tool_list,
                                        binary() | undefined, binary(),
                                        non_neg_integer()}),
    %% socket -> 等待响应的请求 {Ref, FsmPid, Kind, ReqId}
    pending = #{} :: #{gen_tcp:socket() => {reference(), pid() | undefined, llm | tool | tool_list,
                                             binary() | undefined}},
    %% socket -> 超时计时器
    timers = #{} :: #{gen_tcp:socket() => reference()},
    %% req_id -> gen_server From (同步工具调用, 如 memory_search 预取)
    sync_waiters = #{} :: #{binary() => gen_server:from()}
}).

%%%===================================================================
%%% 对外接口
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% 异步调用 LLM: Req = #{model, messages, tools} (无凭证, 由本进程注入)
%% 返回 Ref, FSM 用此 Ref 匹配 {llm_response, Ref, Resp}
call_llm(FsmPid, Req) ->
    Ref = make_ref(),
    gen_server:cast(?MODULE, {call_llm, FsmPid, Ref, Req}),
    Ref.

%% 批量并行派发工具调用 (每个 ToolCall 一条异步请求)
call_tool_batch(FsmPid, ToolCalls) when is_list(ToolCalls) ->
    [call_tool(FsmPid, TC) || TC <- ToolCalls],
    ok.

%% 异步调用单个工具: ToolCall = #{id, name, arguments}
call_tool(FsmPid, #{id := Id, name := Name, arguments := Args}) ->
    Ref = make_ref(),
    gen_server:cast(?MODULE, {call_tool, FsmPid, Ref, Id, Name, Args}),
    Ref.

%% 同步调用单个工具 (阻塞至响应或超时), 供 memory RAG 预取等 FSM 外场景。
%% ToolCall = #{id, name, arguments}; 返回 {ok, Resp} | {error, Reason}
call_tool_sync(#{id := Id, name := Name, arguments := Args}, TimeoutMs)
  when is_integer(TimeoutMs), TimeoutMs > 0 ->
    gen_server:call(?MODULE, {call_tool_sync, Id, Name, Args, TimeoutMs}, TimeoutMs + 2000).

%% 同步查询 Eion-tools 注册的工具列表 -> {ok, [ToolDescMap]} | {error, Reason}
list_tools(TimeoutMs) when is_integer(TimeoutMs), TimeoutMs > 0 ->
    gen_server:call(?MODULE, {list_tools, TimeoutMs}, TimeoutMs + 2000).

%% 调试用: 查看连接池状态
pool_info() ->
    gen_server:call(?MODULE, pool_info).

%%%===================================================================
%%% gen_server 回调
%%%===================================================================

init([]) ->
    {Addr, PoolSize} = resolve_addr(),
    lager:info("bridge_manager init: addr=~s pool_size=~p", [Addr, PoolSize]),
    %% 异步建立连接池 (不阻塞 init)
    self() ! connect_all,
    {ok, #state{addr = Addr, pool_size = PoolSize}}.

handle_call({call_tool_sync, Id, Name, Args, TimeoutMs}, From, State) ->
    lager:info("call_tool_sync queued, tool=~s, req_id=~s, timeout=~pms", [Name, Id, TimeoutMs]),
    BizReq = #{kind => tool_exec,
               req_id => Id,
               tool_name => Name,
               arguments_json => Args},
    Payload = pb_codec:encode_req(BizReq),
    Ref = make_ref(),
    Item = {Ref, undefined, tool, Id, Payload, TimeoutMs},
    State1 = State#state{sync_waiters = maps:put(Id, From, State#state.sync_waiters)},
    {noreply, dispatch(State1, Item)};
handle_call({list_tools, TimeoutMs}, From, State) ->
    lager:info("list_tools queued, timeout=~pms", [TimeoutMs]),
    Id = iolist_to_binary(["list-", integer_to_binary(erlang:unique_integer([positive]))]),
    Payload = pb_codec:encode_req(#{kind => tool_list}),
    Ref = make_ref(),
    Item = {Ref, undefined, tool_list, Id, Payload, TimeoutMs},
    State1 = State#state{sync_waiters = maps:put(Id, From, State#state.sync_waiters)},
    {noreply, dispatch(State1, Item)};
handle_call(pool_info, _From, State) ->
    Info = #{addr => State#state.addr,
             pool_size => State#state.pool_size,
             connected => length([C || C <- State#state.conns, C#conn.socket =/= undefined]),
             idle => length([C || C <- State#state.conns, C#conn.state =:= idle]),
             busy => length([C || C <- State#state.conns, C#conn.state =:= busy]),
             queue_len => queue:len(State#state.queue),
             pending => maps:size(State#state.pending)},
    {reply, Info, State};
handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

handle_cast({call_llm, FsmPid, Ref, Req}, State) ->
    lager:info("call_llm queued, ref=~p, fsm_pid=~p", [Ref, FsmPid]),
    BizReq = inject_llm_creds(Req),
    Payload = pb_codec:encode_req(BizReq),
    Item = {Ref, FsmPid, llm, undefined, Payload, ?LLM_TIMEOUT},
    {noreply, dispatch(State, Item)};

handle_cast({call_tool, FsmPid, Ref, Id, Name, Args}, State) ->
    lager:info("call_tool queued, ref=~p, tool=~s, req_id=~s", [Ref, Name, Id]),
    BizReq = #{kind => tool_exec,
               req_id => Id,
               tool_name => Name,
               arguments_json => Args},
    Payload = pb_codec:encode_req(BizReq),
    Item = {Ref, FsmPid, tool, Id, Payload, ?TOOL_TIMEOUT},
    {noreply, dispatch(State, Item)};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% 建立整个连接池
handle_info(connect_all, #state{addr = Addr, pool_size = N} = State) ->
    lager:info("connect_all: building pool, addr=~s target_size=~p", [Addr, N]),
    {Conns, Failed} = lists:foldl(fun(I, {Acc, F}) ->
        case connect_one(Addr) of
            {ok, Sock} ->
                lager:info("pool slot ~p/~p connected: socket=~p", [I, N, Sock]),
                {[#conn{socket = Sock, state = idle} | Acc], F};
            {error, Reason} ->
                lager:warning("pool slot ~p/~p connect failed: ~p", [I, N, Reason]),
                {Acc, F + 1}
        end
    end, {[], 0}, lists:seq(1, N)),
    Conns1 = lists:reverse(Conns),
    lager:info("pool build done: connected=~p/~p failed=~p",
               [length(Conns1), N, Failed]),
    %% 全部失败才触发全局重连 (避免 N 个重连消息堆积)
    case Conns1 of
        [] ->
            lager:warning("all pool connections failed, full retry in ~pms", [?RECONNECT_DELAY]),
            timer:send_after(?RECONNECT_DELAY, reconnect);
        _ ->
            ok
    end,
    State1 = State#state{conns = Conns1},
    {noreply, dispatch_next(State1)};

%% 重连 (个别连接断开后重连)
handle_info({reconnect, Idx}, #state{addr = Addr, conns = Conns} = State) ->
    lager:info("reconnect slot ~p: addr=~s", [Idx, Addr]),
    case connect_one(Addr) of
        {ok, Sock} ->
            NewConn = #conn{socket = Sock, state = idle},
            %% 替换指定位置的连接 (Idx 从 1 开始)
            Conns1 = lists:sublist(Conns, Idx - 1) ++ [NewConn] ++ lists:nthtail(Idx, Conns),
            lager:info("reconnect slot ~p success: socket=~p", [Idx, Sock]),
            {noreply, dispatch_next(State#state{conns = Conns1})};
        {error, Reason} ->
            lager:warning("reconnect slot ~p failed: ~p, retry in ~pms",
                          [Idx, Reason, ?RECONNECT_DELAY]),
            timer:send_after(?RECONNECT_DELAY, {reconnect, Idx}),
            {noreply, State}
    end;

%% 全局重连 (init 时全部失败)
handle_info(reconnect, #state{addr = Addr, pool_size = N} = State) ->
    lager:info("reconnect (full): addr=~s target_size=~p", [Addr, N]),
    case connect_one(Addr) of
        {ok, Sock} ->
            %% 第一个连接成功, 尝试建立剩余
            Conns = [#conn{socket = Sock, state = idle}],
            self() ! {connect_rest, 2, N},
            lager:info("reconnect first success: socket=~p, building rest of pool", [Sock]),
            {noreply, dispatch_next(State#state{conns = Conns})};
        {error, Reason} ->
            lager:warning("reconnect (full) failed: ~p, retry in ~pms",
                          [Reason, ?RECONNECT_DELAY]),
            timer:send_after(?RECONNECT_DELAY, reconnect),
            {noreply, State}
    end;

%% 逐步建立剩余连接
handle_info({connect_rest, Idx, N}, #state{addr = Addr, conns = Conns} = State) when Idx =< N ->
    case connect_one(Addr) of
        {ok, Sock} ->
            Conns1 = Conns ++ [#conn{socket = Sock, state = idle}],
            lager:info("pool slot ~p/~p connected (rest): socket=~p", [Idx, N, Sock]),
            self() ! {connect_rest, Idx + 1, N},
            {noreply, dispatch_next(State#state{conns = Conns1})};
        {error, Reason} ->
            %% 单个失败不影响整体, 跳过继续
            lager:warning("pool slot ~p/~p connect failed (rest): ~p", [Idx, N, Reason]),
            self() ! {connect_rest, Idx + 1, N},
            {noreply, State}
    end;
handle_info({connect_rest, _Idx, _N}, State) ->
    {noreply, State};

%% TCP 响应: {tcp, Socket, Bin} 是 {packet, 4} 模式下自动去掉长度前缀的负载
%%
%% Task 4 流式: 收到的可能是 llm_chunk (非终态) 或终态 (llm_infer / tool_exec)。
%%   - llm_chunk: 转发 {llm_chunk, Ref, ChunkMap} 给 FSM, 不取消 timer, 不释放连接
%%   - llm_infer (终态): 转发 {llm_response, Ref, Resp}, 取消 timer, 释放连接, dispatch_next
%%   - tool_exec (终态): 转发 {tool_result, ReqId, Resp}, 取消 timer, 释放连接, dispatch_next
handle_info({tcp, Sock, Bin}, #state{pending = Pending, timers = Timers} = State) ->
    case maps:get(Sock, Pending, undefined) of
        {Ref, FsmPid, Kind, ReqId} ->
            Resp = pb_codec:decode_resp(Bin),
            RespKind = maps:get(kind, Resp, unknown),
            lager:info("tcp response received: socket=~p bytes=~p ref=~p kind=~p req_id=~p resp_kind=~p",
                        [Sock, byte_size(Bin), Ref, Kind, ReqId, RespKind]),
            case {Kind, RespKind} of
                {llm, llm_chunk} ->
                    %% 流式 chunk (非终态): 转发, 保持连接 busy, 不动 timer
                    gen_statem:cast(FsmPid, {llm_chunk, Ref, Resp}),
                    {noreply, State};
                {llm, llm_infer} ->
                    %% LLM 终态: 取消 timer, 释放连接, 转发终态响应
                    TRef = maps:get(Sock, Timers, undefined),
                    _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
                    gen_statem:cast(FsmPid, {llm_response, Ref, Resp}),
                    Conns = mark_conn(State#state.conns, Sock, idle),
                    NewState = State#state{conns = Conns,
                                           pending = maps:remove(Sock, Pending),
                                           timers = maps:remove(Sock, Timers)},
                    {noreply, dispatch_next(NewState)};
                {tool, tool_exec} ->
                    %% 工具终态: 取消 timer, 释放连接, 转发结果
                    TRef = maps:get(Sock, Timers, undefined),
                    _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
                    Conns = mark_conn(State#state.conns, Sock, idle),
                    NewState = reply_tool_result(State, ReqId, Resp, Conns, Sock, Pending, Timers),
                    {noreply, dispatch_next(NewState)};
                {tool_list, tool_list} ->
                    TRef = maps:get(Sock, Timers, undefined),
                    _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
                    Conns = mark_conn(State#state.conns, Sock, idle),
                    NewState = reply_tool_list_result(State, ReqId, Resp, Conns, Sock, Pending, Timers),
                    {noreply, dispatch_next(NewState)};
                _Other ->
                    %% 类型不匹配 (如 llm 请求收到 tool_exec 响应): 当作异常, 释放连接
                    lager:warning("unexpected response kind=~p for request kind=~p, releasing conn",
                                  [RespKind, Kind]),
                    TRef = maps:get(Sock, Timers, undefined),
                    _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
                    gen_statem:cast(FsmPid, {bridge_disconnect}),
                    Conns = mark_conn(State#state.conns, Sock, idle),
                    NewState = State#state{conns = Conns,
                                           pending = maps:remove(Sock, Pending),
                                           timers = maps:remove(Sock, Timers)},
                    {noreply, dispatch_next(NewState)}
            end;
        undefined ->
            %% 未知 socket 的数据, 忽略
            lager:warning("tcp data from unknown socket, ignoring"),
            {noreply, State}
    end;

%% 连接断开
handle_info({tcp_closed, Sock}, #state{pending = Pending, timers = Timers, conns = Conns} = State) ->
    Idx = index_of_conn(Conns, Sock),
    case maps:get(Sock, Pending, undefined) of
        {Ref, FsmPid, Kind, ReqId} ->
            lager:warning("tcp connection closed: socket=~p slot=~p, in-flight req lost: ref=~p kind=~p req_id=~p, notifying fsm=~p",
                          [Sock, Idx, Ref, Kind, ReqId, FsmPid]),
            TRef = maps:get(Sock, Timers, undefined),
            _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
            _ = reply_tool_timeout(State, ReqId),
            case FsmPid of
                undefined -> ok;
                _ -> gen_statem:cast(FsmPid, {bridge_disconnect})
            end;
        undefined ->
            lager:warning("tcp connection closed: socket=~p slot=~p (no in-flight req)", [Sock, Idx])
    end,
    %% 标记连接为断开 (socket=undefined), 异步重连
    Conns1 = case Idx of
        0 -> Conns;
        _ -> lists:sublist(Conns, Idx - 1) ++
             [#conn{socket = undefined, state = idle}] ++
             lists:nthtail(Idx, Conns)
    end,
    case Idx of
        0 -> ok;
        _ ->
            lager:info("scheduling reconnect for slot ~p in ~pms", [Idx, ?RECONNECT_DELAY]),
            timer:send_after(?RECONNECT_DELAY, {reconnect, Idx})
    end,
    {noreply, State#state{conns = Conns1,
                          pending = maps:remove(Sock, Pending),
                          timers = maps:remove(Sock, Timers)}};

%% TCP 错误
handle_info({tcp_error, Sock, Reason}, State) ->
    Idx = index_of_conn(State#state.conns, Sock),
    lager:warning("tcp error: socket=~p slot=~p reason=~p, treating as closed", [Sock, Idx, Reason]),
    %% 当作 closed 处理
    handle_info({tcp_closed, Sock}, State);

%% 当前在途请求超时: 通知对应 FSM 断连, 连接回 idle
handle_info({timeout, TRef, {req, Sock, Ref}}, #state{timers = Timers,
                                                       pending = Pending} = State) ->
    case maps:get(Sock, Timers, undefined) of
        TRef ->
            case maps:get(Sock, Pending, undefined) of
                {Ref, FsmPid, Kind, ReqId} ->
                    lager:warning("request timeout: socket=~p ref=~p kind=~p req_id=~p, notifying fsm=~p",
                                  [Sock, Ref, Kind, ReqId, FsmPid]),
                    _ = reply_tool_timeout(State, ReqId),
                    case FsmPid of
                        undefined -> ok;
                        _ -> gen_statem:cast(FsmPid, {bridge_disconnect})
                    end;
                _ ->
                    lager:warning("request timeout but no matching pending: socket=~p ref=~p", [Sock, Ref])
            end,
            Conns = mark_conn(State#state.conns, Sock, idle),
            {noreply, dispatch_next(State#state{conns = Conns,
                                                pending = maps:remove(Sock, Pending),
                                                timers = maps:remove(Sock, Timers)})};
        _ ->
            {noreply, State}
    end;

%% 兜底
handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, State) ->
    Active = [C || C <- State#state.conns, C#conn.socket =/= undefined],
    lager:info("bridge_manager terminating: reason=~p, closing ~p/~p connections",
               [Reason, length(Active), length(State#state.conns)]),
    lists:foreach(fun(#conn{socket = Sock}) ->
        case Sock of
            undefined -> ok;
            _ ->
                lager:info("closing pool socket: ~p", [Sock]),
                try gen_tcp:close(Sock) catch _:_ -> ok end
        end
    end, State#state.conns),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

reply_tool_result(#state{sync_waiters = Sync} = State, ReqId, Resp, Conns, Sock, Pending, Timers) ->
    Base = State#state{conns = Conns,
                       pending = maps:remove(Sock, Pending),
                       timers = maps:remove(Sock, Timers)},
    case maps:get(ReqId, Sync, undefined) of
        undefined ->
            case maps:get(Sock, Pending, undefined) of
                {_, FsmPid, _, _} when FsmPid =/= undefined ->
                    gen_statem:cast(FsmPid, {tool_result, ReqId, Resp});
                _ ->
                    ok
            end,
            Base;
        From ->
            gen_server:reply(From, {ok, Resp}),
            Base#state{sync_waiters = maps:remove(ReqId, Sync)}
    end.

reply_tool_list_result(#state{sync_waiters = Sync} = State, ReqId, Resp, Conns, Sock, Pending, Timers) ->
    Base = State#state{conns = Conns,
                       pending = maps:remove(Sock, Pending),
                       timers = maps:remove(Sock, Timers)},
    case maps:get(ReqId, Sync, undefined) of
        undefined ->
            lager:warning("tool_list response without sync waiter req_id=~s", [ReqId]),
            Base;
        From ->
            Reply = case maps:get(error, Resp, <<>>) of
                        Err when Err =/= <<>> ->
                            {error, Err};
                        _ ->
                            {ok, maps:get(tools, Resp, [])}
                    end,
            gen_server:reply(From, Reply),
            Base#state{sync_waiters = maps:remove(ReqId, Sync)}
    end.

reply_tool_timeout(#state{sync_waiters = Sync} = State, ReqId) ->
    case maps:get(ReqId, Sync, undefined) of
        undefined ->
            ok;
        From ->
            gen_server:reply(From, {error, timeout}),
            State#state{sync_waiters = maps:remove(ReqId, Sync)}
    end.

%%%===================================================================
%%% 内部函数
%%%===================================================================

%% 解析 Eion-tools server 地址
resolve_addr() ->
    Addr = case application:get_env(hermes_brains, eion_tools_addr) of
        {ok, A} when is_list(A), A =/= "" -> A;
        _ ->
            case application:get_env(hermes_brains, eion_tools_addr_file) of
                {ok, File} when is_list(File), File =/= "" -> read_addr_file(File);
                _ -> ?DEFAULT_ADDR
            end
    end,
    PoolSize = application:get_env(hermes_brains, eion_tools_pool_size, ?DEFAULT_POOL_SIZE),
    {Addr, PoolSize}.

%% 从端口文件读取地址 (文件内容: "127.0.0.1:12345" 或 "/tmp/xxx.sock")
read_addr_file(File) ->
    case file:read_file(File) of
        {ok, Bin} ->
            Addr = string:trim(binary_to_list(Bin)),
            lager:info("read addr from file ~s: ~s", [File, Addr]),
            Addr;
        {error, Reason} ->
            lager:warning("read addr file ~s failed: ~p, using default", [File, Reason]),
            ?DEFAULT_ADDR
    end.

%% 建立一个 TCP 连接到 Eion-tools server
%% {packet, 4}: Erlang 自动处理 4 字节大端长度前缀 (与 Go 侧 readFrame 对齐)
%% {active, true}: gen_server 收 {tcp, Socket, Bin} 消息
connect_one(Addr) ->
    {Host, Port} = parse_addr(Addr),
    Opts = [binary, {packet, 4}, {active, true}, {nodelay, true}],
    gen_tcp:connect(Host, Port, Opts, 5000).

%% 解析地址 "127.0.0.1:12345" -> {"127.0.0.1", 12345}
parse_addr(Addr) ->
    case string:split(Addr, ":") of
        [Host, PortStr] ->
            {Host, list_to_integer(PortStr)};
        _ ->
            %% 兜底: 整个当 host, 默认端口
            {Addr, 7891}
    end.

%% 分发: 如果有 idle 连接, 立即发送; 否则排到队列尾部
dispatch(#state{conns = Conns, queue = Q} = State, Item) ->
    case find_idle_conn(Conns) of
        {ok, Sock, Conns1} ->
            send_item(Item, Sock, Conns1, State);
        none ->
            %% 无 idle 连接, 入队
            QLen = queue:len(Q) + 1,
            lager:info("no idle conn, request queued: queue_len=~p", [QLen]),
            State#state{queue = queue:in(Item, Q)}
    end.

%% 派发下一条排队请求 (有 idle 连接时)
dispatch_next(#state{queue = Q, conns = Conns} = State) ->
    case find_idle_conn(Conns) of
        {ok, Sock, Conns1} ->
            case queue:out(Q) of
                {{value, Item}, Q1} ->
                    lager:info("dispatching queued request: remaining_queue=~p", [queue:rlen(Q1)]),
                    send_item(Item, Sock, Conns1, State#state{queue = Q1});
                {empty, _} ->
                    State#state{conns = Conns1}
            end;
        none ->
            State
    end.

%% 实际发送: 把 Payload 写到 Socket, 启动超时计时器, 记录 pending。
send_item({Ref, FsmPid, Kind, ReqId, Payload, TimeoutMs}, Sock, Conns, State) ->
    Bytes = byte_size(Payload),
    case gen_tcp:send(Sock, Payload) of
        ok ->
            lager:info("request sent: socket=~p bytes=~p ref=~p kind=~p req_id=~p timeout=~pms",
                       [Sock, Bytes, Ref, Kind, ReqId, TimeoutMs]),
            TRef = erlang:start_timer(TimeoutMs, self(), {req, Sock, Ref}),
            Conns1 = mark_conn(Conns, Sock, busy),
            State#state{conns = Conns1,
                        pending = maps:put(Sock, {Ref, FsmPid, Kind, ReqId}, State#state.pending),
                        timers = maps:put(Sock, TRef, State#state.timers)};
        {error, Reason} ->
            Idx = index_of_conn(Conns, Sock),
            lager:warning("send failed: socket=~p slot=~p reason=~p, notifying fsm=~p",
                          [Sock, Idx, Reason, FsmPid]),
            gen_statem:cast(FsmPid, {bridge_disconnect}),
            %% 连接标记为断开, 触发重连
            case Idx of
                0 -> State;
                _ ->
                    Conns2 = lists:sublist(Conns, Idx - 1) ++
                             [#conn{socket = undefined, state = idle}] ++
                             lists:nthtail(Idx, Conns),
                    lager:info("scheduling reconnect for slot ~p in ~pms (send failed)", [Idx, ?RECONNECT_DELAY]),
                    timer:send_after(?RECONNECT_DELAY, {reconnect, Idx}),
                    State#state{conns = Conns2}
            end
    end.

%% 找第一个 idle 且有 socket 的连接, 返回 {ok, Sock, Conns1} (Conns1 已标记 busy)
find_idle_conn(Conns) ->
    find_idle_conn(Conns, 1, []).

find_idle_conn([#conn{socket = Sock, state = idle} = C | Rest], _Idx, Acc) when Sock =/= undefined ->
    Conns1 = lists:reverse(Acc) ++ [C#conn{state = busy}] ++ Rest,
    {ok, Sock, Conns1};
find_idle_conn([C | Rest], Idx, Acc) ->
    find_idle_conn(Rest, Idx + 1, [C | Acc]);
find_idle_conn([], _Idx, _Acc) ->
    none.

%% 标记指定 socket 的连接状态
mark_conn(Conns, Sock, NewState) ->
    [case C#conn.socket of
        Sock -> C#conn{state = NewState};
        _ -> C
     end || C <- Conns].

%% 找指定 socket 在连接池中的索引 (1-based), 0 = 未找到
index_of_conn(Conns, Sock) ->
    index_of_conn(Conns, Sock, 1).

index_of_conn([#conn{socket = S} | _], Sock, Idx) when S =:= Sock -> Idx;
index_of_conn([_ | Rest], Sock, Idx) -> index_of_conn(Rest, Sock, Idx + 1);
index_of_conn([], _Sock, _Idx) -> 0.

inject_llm_creds(Req) when is_map(Req) ->
    DefaultBase = application:get_env(hermes_brains, api_base, <<>>),
    DefaultKey = application:get_env(hermes_brains, api_key, <<>>),
    Base = case maps:get(api_base, Req, <<>>) of
               <<>> -> DefaultBase;
               B -> B
           end,
    Key = case maps:get(api_key, Req, <<>>) of
              <<>> -> DefaultKey;
              K -> K
          end,
    Req#{kind => llm_infer, api_base => Base, api_key => Key}.
