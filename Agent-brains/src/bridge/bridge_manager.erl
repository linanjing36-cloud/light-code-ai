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
-export([start_link/0, call_llm/2, call_tool_batch/2, call_tool/2,
         pool_info/0]).
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
    queue = queue:new() :: queue:queue({reference(), pid(), llm | tool,
                                        binary() | undefined, binary(),
                                        non_neg_integer()}),
    %% socket -> 等待响应的请求 {Ref, FsmPid, Kind, ReqId}
    pending = #{} :: #{gen_tcp:socket() => {reference(), pid(), llm | tool,
                                             binary() | undefined}},
    %% socket -> 超时计时器
    timers = #{} :: #{gen_tcp:socket() => reference()}
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
    %% 注入凭证 (来自 app env, 不来自 FSM)
    ApiBase = application:get_env(hermes_brains, api_base, <<>>),
    ApiKey = application:get_env(hermes_brains, api_key, <<>>),
    BizReq = Req#{kind => llm_infer,
                  api_base => ApiBase,
                  api_key => ApiKey},
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
    Conns = lists:foldl(fun(_, Acc) ->
        case connect_one(Addr) of
            {ok, Sock} ->
                [#conn{socket = Sock, state = idle} | Acc];
            {error, Reason} ->
                lager:warning("pool connect failed: ~p, will retry in ~pms",
                              [Reason, ?RECONNECT_DELAY]),
                timer:send_after(?RECONNECT_DELAY, reconnect),
                Acc
        end
    end, [], lists:seq(1, N)),
    lager:info("pool connected: ~p/~p connections", [length(Conns), N]),
    %% 连接池建好后, 派发队列中等待的请求
    State1 = State#state{conns = Conns},
    {noreply, dispatch_next(State1)};

%% 重连 (个别连接断开后重连)
handle_info({reconnect, Idx}, #state{addr = Addr, conns = Conns} = State) ->
    case connect_one(Addr) of
        {ok, Sock} ->
            NewConn = #conn{socket = Sock, state = idle},
            %% 替换指定位置的连接 (Idx 从 1 开始)
            Conns1 = lists:sublist(Conns, Idx - 1) ++ [NewConn] ++ lists:nthtail(Idx, Conns),
            lager:info("reconnected pool slot ~p", [Idx]),
            {noreply, dispatch_next(State#state{conns = Conns1})};
        {error, Reason} ->
            lager:warning("reconnect slot ~p failed: ~p, retry in ~pms",
                          [Idx, Reason, ?RECONNECT_DELAY]),
            timer:send_after(?RECONNECT_DELAY, {reconnect, Idx}),
            {noreply, State}
    end;

%% 全局重连 (init 时全部失败)
handle_info(reconnect, #state{addr = Addr, pool_size = N} = State) ->
    case connect_one(Addr) of
        {ok, Sock} ->
            %% 第一个连接成功, 尝试建立剩余
            Conns = [#conn{socket = Sock, state = idle}],
            self() ! {connect_rest, 2, N},
            lager:info("first connection established, building rest of pool"),
            {noreply, dispatch_next(State#state{conns = Conns})};
        {error, Reason} ->
            lager:warning("reconnect failed: ~p, retry in ~pms",
                          [Reason, ?RECONNECT_DELAY]),
            timer:send_after(?RECONNECT_DELAY, reconnect),
            {noreply, State}
    end;

%% 逐步建立剩余连接
handle_info({connect_rest, Idx, N}, #state{addr = Addr, conns = Conns} = State) when Idx =< N ->
    case connect_one(Addr) of
        {ok, Sock} ->
            Conns1 = Conns ++ [#conn{socket = Sock, state = idle}],
            self() ! {connect_rest, Idx + 1, N},
            {noreply, dispatch_next(State#state{conns = Conns1})};
        {error, _Reason} ->
            %% 单个失败不影响整体, 跳过继续
            self() ! {connect_rest, Idx + 1, N},
            {noreply, State}
    end;
handle_info({connect_rest, _Idx, _N}, State) ->
    {noreply, State};

%% TCP 响应: {tcp, Socket, Bin} 是 {packet, 4} 模式下自动去掉长度前缀的负载
handle_info({tcp, Sock, Bin}, #state{pending = Pending, timers = Timers} = State) ->
    case maps:get(Sock, Pending, undefined) of
        {Ref, FsmPid, Kind, ReqId} ->
            TRef = maps:get(Sock, Timers, undefined),
            _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
            %% 解码 protobuf 响应 -> 业务 Map
            Resp = pb_codec:decode_resp(Bin),
            lager:info("tcp response received: bytes=~p, ref=~p, kind=~p",
                        [byte_size(Bin), Ref, Kind]),
            %% 按 Kind 投回对应 FSM
            case Kind of
                llm  -> gen_statem:cast(FsmPid, {llm_response, Ref, Resp});
                tool -> gen_statem:cast(FsmPid, {tool_result, ReqId, Resp})
            end,
            %% 连接回 idle
            Conns = mark_conn(State#state.conns, Sock, idle),
            NewState = State#state{conns = Conns,
                                   pending = maps:remove(Sock, Pending),
                                   timers = maps:remove(Sock, Timers)},
            %% 发下一条排队请求
            {noreply, dispatch_next(NewState)};
        undefined ->
            %% 未知 socket 的数据, 忽略
            lager:warning("tcp data from unknown socket, ignoring"),
            {noreply, State}
    end;

%% 连接断开
handle_info({tcp_closed, Sock}, #state{pending = Pending, timers = Timers, conns = Conns} = State) ->
    lager:warning("tcp connection closed: socket=~p", [Sock]),
    %% 通知等待中的 FSM 断连
    case maps:get(Sock, Pending, undefined) of
        {_Ref, FsmPid, _Kind, _ReqId} ->
            TRef = maps:get(Sock, Timers, undefined),
            _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
            gen_statem:cast(FsmPid, {bridge_disconnect});
        undefined ->
            ok
    end,
    %% 标记连接为断开 (socket=undefined), 异步重连
    Idx = index_of_conn(Conns, Sock),
    Conns1 = case Idx of
        0 -> Conns;
        _ -> lists:sublist(Conns, Idx - 1) ++
             [#conn{socket = undefined, state = idle}] ++
             lists:nthtail(Idx, Conns)
    end,
    case Idx of
        0 -> ok;
        _ -> timer:send_after(?RECONNECT_DELAY, {reconnect, Idx})
    end,
    {noreply, State#state{conns = Conns1,
                          pending = maps:remove(Sock, Pending),
                          timers = maps:remove(Sock, Timers)}};

%% TCP 错误
handle_info({tcp_error, Sock, Reason}, State) ->
    lager:warning("tcp error: socket=~p reason=~p", [Sock, Reason]),
    %% 当作 closed 处理
    handle_info({tcp_closed, Sock}, State);

%% 当前在途请求超时: 通知对应 FSM 断连, 连接回 idle
handle_info({timeout, TRef, {req, Sock, Ref}}, #state{timers = Timers,
                                                       pending = Pending} = State) ->
    case maps:get(Sock, Timers, undefined) of
        TRef ->
            case maps:get(Sock, Pending, undefined) of
                {Ref, FsmPid, _Kind, _ReqId} ->
                    lager:warning("request timeout, ref=~p, notifying fsm=~p", [Ref, FsmPid]),
                    gen_statem:cast(FsmPid, {bridge_disconnect});
                _ ->
                    ok
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

terminate(_Reason, State) ->
    %% 关闭所有连接
    lists:foreach(fun(#conn{socket = Sock}) ->
        case Sock of
            undefined -> ok;
            _ -> try gen_tcp:close(Sock) catch _:_ -> ok end
        end
    end, State#state.conns),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

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
dispatch(#state{conns = Conns} = State, Item) ->
    case find_idle_conn(Conns) of
        {ok, Sock, Conns1} ->
            send_item(Item, Sock, Conns1, State);
        none ->
            %% 无 idle 连接, 入队
            State#state{queue = queue:in(Item, State#state.queue)}
    end.

%% 派发下一条排队请求 (有 idle 连接时)
dispatch_next(#state{queue = Q, conns = Conns} = State) ->
    case find_idle_conn(Conns) of
        {ok, Sock, Conns1} ->
            case queue:out(Q) of
                {{value, Item}, Q1} ->
                    send_item(Item, Sock, Conns1, State#state{queue = Q1});
                {empty, _} ->
                    State#state{conns = Conns1}
            end;
        none ->
            State
    end.

%% 实际发送: 把 Payload 写到 Socket, 启动超时计时器, 记录 pending。
send_item({Ref, FsmPid, Kind, ReqId, Payload, TimeoutMs}, Sock, Conns, State) ->
    case gen_tcp:send(Sock, Payload) of
        ok ->
            TRef = erlang:start_timer(TimeoutMs, self(), {req, Sock, Ref}),
            Conns1 = mark_conn(Conns, Sock, busy),
            State#state{conns = Conns1,
                        pending = maps:put(Sock, {Ref, FsmPid, Kind, ReqId}, State#state.pending),
                        timers = maps:put(Sock, TRef, State#state.timers)};
        {error, Reason} ->
            lager:warning("send failed: ~p, notifying fsm=~p", [Reason, FsmPid]),
            gen_statem:cast(FsmPid, {bridge_disconnect}),
            %% 连接标记为断开, 触发重连
            Idx = index_of_conn(Conns, Sock),
            case Idx of
                0 -> State;
                _ ->
                    Conns2 = lists:sublist(Conns, Idx - 1) ++
                             [#conn{socket = undefined, state = idle}] ++
                             lists:nthtail(Idx, Conns),
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
