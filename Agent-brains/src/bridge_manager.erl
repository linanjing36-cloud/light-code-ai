-module(bridge_manager).
-behaviour(gen_server).

%%====================================================================
%% Bridge_Manager —— Go 侧 Eion-tools 连接管理器 (端口模式)
%%====================================================================
%%
%% 职责:
%%   - 在 init 时用 erlang:open_port 拉起 Eion-tools server 子进程
%%   - 维护一个 FIFO 请求队列: 业务请求经 pb_codec 编码为 Protobuf 二进制后排队
%%   - 串行投递: 一次只发一条请求到 Port, 等到响应再发下一条
%%     (Go 侧 server 也是串行 read-frame / write-frame, 二者节奏匹配)
%%   - 监听 Port 的 {data, Bin} 响应, 解码后按 Ref 投回对应 FSM
%%   - 超时管理: 单次原子请求超时即失败上报, 不在 Go 侧重试 (无状态原则)
%%   - Port 异常退出: 通知所有等待中的 FSM ({bridge_disconnect})
%%
%% 接口语义: 全部异步 (cast)。返回 Ref 供 FSM 匹配响应。
%%   call_llm(FsmPid, Req)          -> Ref          响应回投 {llm_response, Ref, Resp}
%%   call_tool_batch(FsmPid, TCs)   -> ok           每条响应回投 {tool_result, ToolCallId, Resp}
%%
%% 凭证处理: api_base / api_key 由本进程从 app env 注入, 不进入 FSM 状态,
%% 也不经过 context_assembler, 以缩小秘密的暴露面。
%%
%% 帧格式 (与 Eion-tools cmd/server/main.go 对齐):
%%   4 字节大端长度前缀 + protobuf 负载
%%   erlang:open_port([binary, {packet, 4}, use_stdio]) 自动处理 4 字节长度前缀
%%====================================================================

%% 对外接口
-export([start_link/0, call_llm/2, call_tool_batch/2, call_tool/2,
         port_info/0, queue_len/0]).
%% gen_server 回调
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(LLM_TIMEOUT, 60000).   %% 单次 LLM 推理超时 (v4-pro 推理模型可能较慢)
-define(TOOL_TIMEOUT, 15000).  %% 单次工具执行超时

-record(state, {
    %% Eion-tools server 的 Port 句柄
    port :: port() | undefined,
    %% FIFO 队列: 等待发送的请求 {Ref, FsmPid, Kind, ReqId, Payload, Timeout}
    %%   Kind = llm | tool ; ReqId = tool_call.id (tool) | undefined (llm)
    queue = queue:new() :: queue:queue({reference(), pid(), llm | tool,
                                        binary() | undefined, binary(),
                                        non_neg_integer()}),
    %% 当前在途请求 (已发到 Port, 等响应)
    current :: {reference(), pid(), llm | tool, binary() | undefined} | undefined,
    %% 当前在途请求的超时计时器
    timer :: reference() | undefined
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
%% 注意: 端口模式下, 实际是串行入队, 但对 FSM 来说是 fire-and-forget
call_tool_batch(FsmPid, ToolCalls) when is_list(ToolCalls) ->
    [call_tool(FsmPid, TC) || TC <- ToolCalls],
    ok.

%% 异步调用单个工具: ToolCall = #{id, name, arguments}
call_tool(FsmPid, #{id := Id, name := Name, arguments := Args}) ->
    Ref = make_ref(),
    gen_server:cast(?MODULE, {call_tool, FsmPid, Ref, Id, Name, Args}),
    Ref.

%% 调试用: 查看 Port 状态
port_info() ->
    gen_server:call(?MODULE, port_info).

%% 调试用: 查看队列长度
queue_len() ->
    gen_server:call(?MODULE, queue_len).

%%%===================================================================
%%% gen_server 回调
%%%===================================================================

init([]) ->
    ServerBin = application:get_env(hermes_brains, eion_tools_bin,
                                    "eion-tools-server"),
    %% 拉起 Eion-tools server 子进程
    %% {packet, 4}: Erlang 自动处理 4 字节大端长度前缀 (与 Go 侧 readFrame 对齐)
    %% use_stdio + binary: 用 stdin/stdout 通信, 数据以 binary 传输
    %% 注意: 不开 stderr_to_stdout —— 否则 Go 侧 log.Println 输出的非 framed 文本
    %%       会污染 stdout 的 packet 流, 破坏 {packet,4} 解析。Go 的 stderr 直接
    %%       继承到调用进程的 stderr, 在终端里仍可见, 不影响端口数据流。
    Port = erlang:open_port({spawn, ServerBin},
                            [binary, {packet, 4}, use_stdio, exit_status]),
    {ok, #state{port = Port}}.

handle_call(port_info, _From, #state{port = Port} = State) ->
    {reply, Port, State};
handle_call(queue_len, _From, State) ->
    {reply, queue:len(State#state.queue), State};
handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

handle_cast({call_llm, FsmPid, Ref, Req}, State) ->
    %% 注入凭证 (来自 app env, 不来自 FSM)
    ApiBase = application:get_env(hermes_brains, api_base, <<>>),
    ApiKey = application:get_env(hermes_brains, api_key, <<>>),
    BizReq = Req#{kind => llm_infer,
                  api_base => ApiBase,
                  api_key => ApiKey},
    Payload = pb_codec:encode_req(BizReq),
    enqueue_and_maybe_send({Ref, FsmPid, llm, undefined, Payload, ?LLM_TIMEOUT},
                           State);

handle_cast({call_tool, FsmPid, Ref, Id, Name, Args}, State) ->
    BizReq = #{kind => tool_exec,
               req_id => Id,
               tool_name => Name,
               arguments_json => Args},
    Payload = pb_codec:encode_req(BizReq),
    enqueue_and_maybe_send({Ref, FsmPid, tool, Id, Payload, ?TOOL_TIMEOUT},
                           State);

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Port 响应回包: {data, Bin} 是 {packet, 4} 模式下 Erlang 自动去掉长度前缀的负载
handle_info({Port, {data, Bin}}, #state{port = Port,
                                        current = {Ref, FsmPid, Kind, ReqId},
                                        timer = TRef} = State) ->
    error_logger:info_msg("[bridge] got port data: ~p bytes, current Ref=~p~n",
                         [byte_size(Bin), Ref]),
    %% 取消当前在途请求的超时计时器
    _ = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
    %% 解码 protobuf 响应 -> 业务 Map
    Resp = pb_codec:decode_resp(Bin),
    error_logger:info_msg("[bridge] decoded resp kind=~p, content_size=~p~n",
                         [maps:get(kind, Resp, unknown),
                          byte_size(maps:get(content, Resp, <<>>))]),
    %% 按 Kind 投回对应 FSM
    case Kind of
        llm   -> gen_statem:cast(FsmPid, {llm_response, Ref, Resp});
        tool  -> gen_statem:cast(FsmPid, {tool_result, ReqId, Resp})
    end,
    %% 发下一条排队请求
    {noreply, dispatch_next(State#state{current = undefined, timer = undefined})};

%% 调试: 收到任何 Port 消息但 current 不匹配时打印
handle_info({Port, Other}, #state{port = Port} = State) ->
    error_logger:info_msg("[bridge] unexpected port msg: ~p~n", [Other]),
    {noreply, State};

%% Port 进程退出: Go 侧崩溃, 通知所有等待中的 FSM 并尝试重启 Port
handle_info({Port, {exit_status, Status}}, #state{port = Port} = State) ->
    error_logger:warning_msg("Eion-tools server exited: ~p, restarting port~n",
                             [Status]),
    notify_all_disconnect(State),
    ServerBin = application:get_env(hermes_brains, eion_tools_bin,
                                    "eion-tools-server"),
    NewPort = erlang:open_port({spawn, ServerBin},
                               [binary, {packet, 4}, use_stdio, exit_status]),
    {noreply, #state{port = NewPort}};

%% 当前在途请求超时: 通知对应 FSM 断连, 发下一条
handle_info({timeout, TRef, {req, Ref}}, #state{timer = TRef,
                                                 current = {Ref, FsmPid, _Kind, _ReqId}} = State) ->
    gen_statem:cast(FsmPid, {bridge_disconnect}),
    {noreply, dispatch_next(State#state{current = undefined, timer = undefined})};

%% 兜底: 已取消的超时消息等
handle_info({timeout, _TRef, {req, _Ref}}, State) ->
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% 内部函数
%%%===================================================================

%% 入队请求: 如果当前无在途请求, 立即发送; 否则排到队列尾部
enqueue_and_maybe_send(Item, #state{current = undefined} = State) ->
    send_item(Item, State);
enqueue_and_maybe_send(Item, #state{queue = Q} = State) ->
    {noreply, State#state{queue = queue:in(Item, Q)}}.

%% 实际发送: 把 Payload 写到 Port, 启动超时计时器, 设置 current
send_item({Ref, FsmPid, Kind, ReqId, Payload, TimeoutMs}, #state{port = Port} = State) ->
    Port ! {self(), {command, Payload}},
    TRef = erlang:start_timer(TimeoutMs, self(), {req, Ref}),
    {noreply, State#state{current = {Ref, FsmPid, Kind, ReqId}, timer = TRef}}.

%% 派发下一条排队请求 (current 已清空时调用)
dispatch_next(#state{queue = Q} = State) ->
    case queue:out(Q) of
        {{value, Item}, Q1} ->
            {ok, NewState} = send_item(Item, State#state{queue = Q1}),
            NewState;
        {empty, _Q} ->
            %% 队列空, 进入空闲
            State
    end.

%% 通知所有等待中的 FSM 断连 (包括在途请求 + 队列中的请求)
notify_all_disconnect(#state{current = Current, queue = Q}) ->
    PendingFsms = case Current of
                      {_Ref, FsmPid, _Kind, _ReqId} -> [FsmPid];
                      undefined -> []
                  end,
    QueuedFsms = [FsmPid || {_Ref, FsmPid, _Kind, _ReqId, _Payload, _Timeout} <-
                            queue:to_list(Q)],
    lists:foreach(fun(FsmPid) -> gen_statem:cast(FsmPid, {bridge_disconnect}) end,
                  PendingFsms ++ QueuedFsms).

terminate(_Reason, #state{port = Port}) ->
    %% 优雅关闭 Port (发送 exit 给 Go 进程)
    catch erlang:port_close(Port),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
