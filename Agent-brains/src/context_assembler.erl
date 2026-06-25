-module(context_assembler).

-export([build/2]).

%%====================================================================
%% Context_Assembler —— 上下文组装器 (纯函数式, 无副作用)
%%====================================================================
%%
%% 职责: 把 System Prompt + 历史 + 工具描述组装成 LLMInferRequest 的业务 Map。
%% 不读外部状态、不发消息、不落盘 —— 所有输入由调用方 (agent_fsm) 显式传入。
%%
%% 输出 Map 与 hermes.proto 的 LLMInferRequest 字段对齐:
%%   #{model, messages, tools}
%%   (api_base / api_key 等凭证由 bridge_manager 注入, 不在此暴露)
%%
%% 注意: 本模块刻意不接触凭证, 以免秘密流入 FSM 状态或日志。
%%====================================================================

-spec build(binary(), map()) -> map().
build(Model, Ctx) ->
    History = maps:get(history, Ctx, []),
    Tools = maps:get(tools, Ctx, []),
    Messages = [#{role => <<"system">>, content => system_prompt()}
                | normalize_history(History)],
    #{
        model => Model,
        messages => Messages,
        tools => normalize_tools(Tools)
    }.

%% 系统提示词: 约束 LLM 行为, 强调"一次一步"。
%% 明示 LLM: 不要自行链式调用, 循环与并行由 Erlang 大脑负责 ——
%% 这是防止 Eino 侧控制权泄漏的提示层防线。
system_prompt() ->
    <<"You are a ReAct agent orchestrated by the Erlang brain. "
      "Reason step-by-step and emit tool_calls when an action is needed. "
      "Do NOT attempt to chain multiple actions yourself, and do NOT assume "
      "any tool result is persistent on the Go side — the brain owns all "
      "looping, parallel dispatch and state.">>.

%% 将历史消息标准化 (确保 role/content 字段存在, 兼容 {tool, _} 形式)
normalize_history(History) ->
    [normalize_msg(M) || M <- History].

normalize_msg({tool, ToolMsg}) ->
    %% 兼容旧的 {tool, ...} 形式 -> Message map
    ToolMsg;
normalize_msg(#{role := _, content := _} = M) ->
    M;
normalize_msg(M) when is_map(M) ->
    M;
normalize_msg(_Other) ->
    %% 容错: 无法识别的历史项跳过为空 user 消息
    #{role => <<"user">>, content => <<>>}.

%% 标准化工具描述 (ToolDesc: name, description, parameters_json)
normalize_tools(Tools) ->
    [normalize_tool(T) || T <- Tools].

normalize_tool(#{name := _} = T) ->
    T#{parameters_json => maps:get(parameters_json, T, <<>>)};
normalize_tool(T) when is_map(T) ->
    T.
