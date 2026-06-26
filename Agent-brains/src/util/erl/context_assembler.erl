-module(context_assembler).

-export([build/2]).

%%====================================================================
%% Context_Assembler —— 上下文组装器 (纯函数式, 无副作用)
%%====================================================================
%%
%% 职责: 把 System Prompt + 历史 + 工具描述 + 失败案例组装成 LLMInferRequest
%% 的业务 Map。不读外部状态、不发消息、不落盘 —— 所有输入由调用方 (agent_fsm)
%% 显式传入。
%%
%% 输出 Map 与 hermes.proto 的 LLMInferRequest 字段对齐:
%%   #{model, messages, tools}
%%   (api_base / api_key 等凭证由 bridge_manager 注入, 不在此暴露)
%%
%% 失败案例注入 (Task 1 负面案例记忆):
%%   调用方在 thinking(enter) 前经 case_store:query 拿到最近 N 条案例,
%%   通过 Ctx.failure_cases 传入。本模块将其格式化为"负面案例"段,
%%   拼接到 System Prompt 末尾, 让 LLM 看到之前踩过的坑避免重蹈覆辙。
%%   无案例时 System Prompt 退化为基线版本, 不增加 token。
%%
%% 注意: 本模块刻意不接触凭证, 以免秘密流入 FSM 状态或日志。
%%====================================================================

-spec build(binary(), map()) -> map().
build(Model, Ctx) ->
    History = maps:get(history, Ctx, []),
    Tools = maps:get(tools, Ctx, []),
    Cases = maps:get(failure_cases, Ctx, []),
    Messages = [#{role => <<"system">>, content => system_prompt(Cases)}
                | normalize_history(History)],
    #{
        model => Model,
        messages => Messages,
        tools => normalize_tools(Tools),
        %% Task 4 流式输出: 让 Go 侧 (Eion-tools) 用 Eino Stream API 按 chunk 发,
        %% bridge_manager 转发 {llm_chunk, Ref, Chunk} 给 FSM, FSM 再 push 到 panel。
        stream => true
    }.

%% 系统提示词: 约束 LLM 行为, 强调"一次一步"。
%% 明示 LLM: 不要自行链式调用, 循环与并行由 Erlang 大脑负责 ——
%% 这是防止 Eino 侧控制权泄漏的提示层防线。
%% 有失败案例时, 末尾拼接"负面案例"段。
system_prompt(Cases) when is_list(Cases), Cases =/= [] ->
    Base = system_prompt_base(),
    CasesBin = format_cases(Cases),
    iolist_to_binary([Base, <<"\n\n">>,
                      util:u("## 负面案例 (避免重复踩坑)\n"),
                      CasesBin]);
system_prompt(_) ->
    system_prompt_base().

system_prompt_base() ->
    <<"You are a ReAct agent orchestrated by the Erlang brain. "
      "Reason step-by-step and emit tool_calls when an action is needed. "
      "Do NOT attempt to chain multiple actions yourself, and do NOT assume "
      "any tool result is persistent on the Go side — the brain owns all "
      "looping, parallel dispatch and state.">>.

%% 格式化案例列表为多行文本 (每条一行, 字段紧凑展示)
format_cases(Cases) ->
    Lines = [format_case(C) || C <- Cases],
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

%% 单条案例格式化: 只输出非空字段, 截断超长内容防止 prompt 膨胀
format_case(C) ->
    Scenario = maps:get(scenario, C, <<>>),
    Tool = maps:get(tool_name, C, <<>>),
    Attempted = maps:get(attempted, C, <<>>),
    Reason = maps:get(failure_reason, C, <<>>),
    Lesson = maps:get(lesson, C, <<>>),
    Items = [{<<"scenario">>, Scenario},
             {<<"tool">>, Tool},
             {<<"attempted">>, truncate(Attempted, 120)},
             {<<"error">>, truncate(Reason, 200)},
             {<<"lesson">>, Lesson}],
    Filtered = [{K, V} || {K, V} <- Items, V =/= <<>>, V =/= ""],
    Fields = [<<K/binary, ": ", V/binary>> || {K, V} <- Filtered],
    iolist_to_binary([<<"- ">>, lists:join(<<", ">>, Fields)]).

truncate(Bin, Max) when is_binary(Bin), byte_size(Bin) > Max ->
    <<Bin:Max/binary, "..."/utf8>>;
truncate(Bin, _Max) when is_binary(Bin) ->
    Bin;
truncate(Other, _Max) ->
    Other.

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
