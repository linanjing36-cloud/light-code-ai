-module(hermes_brains_app).
-behaviour(application).

%% Agent-brains 应用入口: 启动顶层监督者 + (可选) panel_server。
%% 编排哲学: Erlang 是唯一的控制中心 —— ReAct 循环、上下文组装、并行工具派发、
%% 故障恢复全部在此节点完成; Go 侧 Eion-tools 仅做无状态原子执行。

-export([start/2, stop/1, serve/0]).

start(_StartType, _StartArgs) ->
    hermes_brains_sup:start_link().

stop(_State) ->
    ok.

%% serve/0 由 Wails(Go) 侧通过 erl -eval 调用:
%%   erl -eval "application:ensure_all_started(hermes_brains), hermes_brains_app:serve()."
%% 启动 panel_server (TCP+JSON RPC), 然后阻塞主进程直到应用退出。
%%
%% panel_server 启动后会向 stdout 打印 "PANEL_PORT:<port>" 行,
%% Wails(Go) 侧读这一行拿到端口号, 再建立 TCP 连接进行后续 RPC 调用。
serve() ->
    case panel_server:start_link() of
        {ok, _Pid} ->
            %% 阻塞主进程, 直到 application controller 触发 stop (rpc init:stop)
            receive
                stop -> ok
            end;
        {error, _} = Err ->
            io:format(standard_error, "[hermes_brains_app] panel_server start failed: ~p~n", [Err]),
            init:stop()
    end.
