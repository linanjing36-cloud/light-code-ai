-module(hermes_brains_app).
-behaviour(application).

%% Agent-brains 应用入口: 启动顶层监督者。
%% 编排哲学: Erlang 是唯一的控制中心 —— ReAct 循环、上下文组装、并行工具派发、
%% 故障恢复全部在此节点完成; Go 侧 Eion-tools 仅做无状态原子执行。

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    hermes_brains_sup:start_link().

stop(_State) ->
    ok.
