-module(panel_server).
-behaviour(gen_server).

%%====================================================================
%% Panel_Server —— Hermes 面板与 Erlang 大脑之间的 JSON-RPC 桥 (TCP)
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
%% 协议:
%%   - 帧格式: 4 字节大端长度 + JSON body
%%   - 请求: {"id": <int>, "method": "<name>", "args": {...}}
%%   - 响应: {"id": <int>, "result": <any>, "error": <string|null>}
%%
%% 启动流程 (独立启动模式):
%%   1. 在 127.0.0.1 上 listen 一个 ephemeral port (port 0)
%%   2. 把完整地址 "127.0.0.1:<port>" 写入端口文件 (供 Wails 读取发现)
%%      同时仍向 stdout 打印 "PANEL_PORT:<port>" 行 (兼容旧脚本/调试)
%%   3. spawn 一个 acceptor 进程, 每个连接再 spawn 一个 connection 进程
%%      (多连接天然并发, 支持 Wails 侧连接池并发请求)
%%
%% 端口文件路径解析 (优先级):
%%   1. app env panel_addr_file (由 -hermes_brains panel_addr_file "path" 注入)
%%   2. 环境变量 PANEL_ADDR_FILE
%%   3. 默认 "panel.addr" (相对 erl cwd, 通常 bin/erl_bin/ 或 Agent-brains/)
%%
%% 支持的方法 (与 Go 侧 brain.Bridge.Call / HermesService 对齐):
%%   start_session   [{system_prompt}]              -> #{session_id => binary()}
%%   send            [{session_id, message}]        -> #{stream_id => binary()}
%%   list_tools      []                              -> #{tools => []}
%%   approve         [{req_id, allow}]               -> #{ok => true}
%%   brain_status    [{session_id}]                 -> #{state, loop_count, ...}
%%   stop            []                              -> 触发 init:stop() 优雅退出
%%
%% 用 OTP 27+ 自带的 json 模块 (无需第三方依赖)。

-export([start_link/0, serve/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    listen_socket :: gen_tcp:socket(),
    port :: inet:port_number()
}).

-define(LOG_INFO(Fmt, Args), io:format(standard_error, "[panel] " ++ Fmt ++ "~n", Args)).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% serve/0: 兼容旧入口 (直接由 hermes_brains_app:serve/0 调用 start_link 也可)
serve() ->
    case panel_server:start_link() of
        {ok, _Pid} -> ok;
        {error, _} = Err -> Err
    end.

%%====================================================================
%% gen_server 回调
%%====================================================================

init([]) ->
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
            %% 把完整地址写入端口文件, 供 Wails 侧读取发现 (新架构: 独立启动)
            case write_addr_file(Addr) of
                ok -> ?LOG_INFO("panel addr file written: ~s (~s)", [panel_addr_file(), Addr]);
                {error, WErr} -> ?LOG_INFO("write panel addr file failed: ~p (addr=~s)", [WErr, Addr])
            end,
            %% 兼容旧脚本/调试: 仍向 stdout 打印 PANEL_PORT 行
            io:format("PANEL_PORT:~p~n", [Port]),
            %% 启动 acceptor (单独进程, 不阻塞 gen_server)
            Acceptor = spawn(fun() -> accept_loop(Sock) end),
            %% gen_server 持有引用, 防止被 GC (虽然 Sock 已经在 state 里)
            erlang:link(Acceptor),
            {ok, #state{listen_socket = Sock, port = Port}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{listen_socket = Sock}) ->
    try gen_tcp:close(Sock) catch _:_ -> ok end,
    %% 清理端口文件 (避免下次启动读到旧地址)
    _ = file:delete(panel_addr_file()),
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% 内部: acceptor loop (单独进程, 持续 accept 新连接)
%%====================================================================

accept_loop(Sock) ->
    case gen_tcp:accept(Sock) of
        {ok, Conn} ->
            %% 每个连接 spawn 一个 connection 进程, 不阻塞 acceptor
            spawn(fun() -> connection_loop(Conn) end),
            accept_loop(Sock);
        {error, closed} ->
            ok;
        {error, Reason} ->
            ?LOG_INFO("accept failed: ~p", [Reason]),
            ok
    end.

%%====================================================================
%% 内部: connection loop (每连接一个进程, 持续读帧分发)
%%====================================================================

connection_loop(Sock) ->
    case read_frame(Sock) of
        {ok, Req} ->
            Resp = dispatch(Req),
            ok = write_frame(Sock, Resp),
            connection_loop(Sock);
        {error, closed} ->
            ok;
        {error, Reason} ->
            ?LOG_INFO("conn read failed: ~p", [Reason]),
            ok
    end.

%% 读取一帧: 4 字节大端长度 + JSON body
read_frame(Sock) ->
    case gen_tcp:recv(Sock, 4) of
        {ok, LenBin} ->
            <<Len:32/big>> = LenBin,
            case gen_tcp:recv(Sock, Len) of
                {ok, Body} ->
                    try json:decode(Body) of
                        Term when is_map(Term) -> {ok, Term};
                        Term -> {ok, Term}
                    catch
                        Class:Reason ->
                            ?LOG_INFO("json decode failed: ~p:~p", [Class, Reason]),
                            {error, bad_json}
                    end;
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

%% 写一帧: 4 字节大端长度 + JSON body
write_frame(Sock, Term) ->
    Body = erlang:iolist_to_binary(json:encode(Term)),
    Len = byte_size(Body),
    Frame = <<Len:32/big, Body/binary>>,
    gen_tcp:send(Sock, Frame).

%%====================================================================
%% 调度: Method -> Handler
%%====================================================================

dispatch(Req) when is_map(Req) ->
    Id = maps:get(<<"id">>, Req, 0),
    Method = maps:get(<<"method">>, Req, <<>>),
    Args = maps:get(<<"args">>, Req, #{}),
    try handle_method(Method, Args) of
        Result ->
            #{id => Id, result => Result}
    catch
        Class:Reason:Stack ->
            ?LOG_INFO("dispatch ~p failed: ~p:~p~n~p", [Method, Class, Reason, Stack]),
            ErrMsg = io_lib:format("~p:~p", [Class, Reason]),
            #{id => Id, error => erlang:iolist_to_binary(ErrMsg)}
    end;
dispatch(Other) ->
    #{id => 0, error => erlang:iolist_to_binary(
        io_lib:format("invalid request: ~p", [Other]))}.

%% ---- start_session: 派发一个 agent_fsm 进程 ----
handle_method(<<"start_session">>, Args) ->
    SystemPrompt = maps:get(<<"system_prompt">>, Args, <<>>),
    SessionId = generate_session_id(),
    Model = application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>),
    FSMArgs = [{session_id, SessionId},
               {model, Model},
               {tools, []},
               {history, [#{role => <<"system">>, content => SystemPrompt}]}],
    case agent_sup:start_agent(FSMArgs) of
        {ok, Pid} ->
            ok = state_store:register_session(SessionId, Pid),
            ?LOG_INFO("session started: id=~p pid=~p", [SessionId, Pid]),
            #{session_id => SessionId};
        {error, Reason} ->
            error({start_agent_failed, Reason})
    end;

%% ---- send: 触发 ReAct 循环 ----
handle_method(<<"send">>, Args) ->
    SessionId = maps:get(<<"session_id">>, Args),
    Message = maps:get(<<"message">>, Args),
    case state_store:lookup_session(SessionId) of
        {ok, Pid} ->
            %% 追加 user message 到 history (双写: state_store + FSM 内部 history)
            UserMsg = #{role => <<"user">>, content => Message},
            ok = state_store:append_history(SessionId, UserMsg),
            %% 触发 ReAct (cast, 异步; 当前不等待 final answer)
            agent_fsm:start(Pid, #{}),
            StreamId = generate_stream_id(),
            #{stream_id => StreamId};
        not_found ->
            error({session_not_found, SessionId})
    end;

%% ---- list_tools: 占位 ----
handle_method(<<"list_tools">>, _Args) ->
    %% TODO: 待 Eion-tools 接入后从 bridge_manager 取注册的工具描述
    #{tools => []};

%% ---- approve: 工具调用授权 (占位, 待 inline approval 实现后补) ----
handle_method(<<"approve">>, _Args) ->
    #{ok => true};

%% ---- brain_status: 读 FSM 当前状态 ----
handle_method(<<"brain_status">>, Args) ->
    SessionId = maps:get(<<"session_id">>, Args, <<>>),
    case state_store:lookup_session(SessionId) of
        {ok, Pid} ->
            agent_fsm:status(Pid);
        not_found ->
            #{state => not_found}
    end;

%% ---- stop: 优雅退出整个 erl 节点 (rpc init:stop) ----
handle_method(<<"stop">>, _Args) ->
    %% 100ms 后异步触发 init:stop, 让本响应先回给 Go 侧
    spawn(fun() -> timer:sleep(100), init:stop() end),
    #{ok => true};

%% ---- 兜底 ----
handle_method(Method, _Args) ->
    error({unknown_method, Method}).

%%====================================================================
%% 内部: id 生成
%%====================================================================

generate_session_id() ->
    Ts = integer_to_binary(erlang:system_time(millisecond)),
    Rand = integer_to_binary(rand:uniform(999999)),
    <<"sess-", Ts/binary, "-", Rand/binary>>.

generate_stream_id() ->
    Ts = integer_to_binary(erlang:system_time(millisecond)),
    <<"stream-", Ts/binary>>.

%%====================================================================
%% 内部: 端口文件 (地址发现)
%%====================================================================

%% 端口文件路径解析 (优先级):
%%   1. app env panel_addr_file
%%   2. 环境变量 PANEL_ADDR_FILE
%%   3. 默认 "panel.addr" (相对 erl cwd)
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

%% 把完整地址 "127.0.0.1:<port>" 写入端口文件, 供 Wails 侧读取发现。
write_addr_file(Addr) when is_list(Addr); is_binary(Addr) ->
    file:write_file(panel_addr_file(), Addr).
