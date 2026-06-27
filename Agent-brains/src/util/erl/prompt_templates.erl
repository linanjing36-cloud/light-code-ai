-module(prompt_templates).

%% Step 4.3 Prompt Engineering: 按 FSM 阶段选择提示词片段
-export([core/0, phase_hint/1]).

-type phase() :: first_turn | thinking | after_tool_error
             | after_bridge_disconnect | near_loop_limit.

-spec core() -> binary().
core() ->
    <<"You are a ReAct agent orchestrated by the Erlang brain. "
      "Reason step-by-step and emit tool_calls when an action is needed. "
      "Do NOT attempt to chain multiple actions yourself, and do NOT assume "
      "any tool result is persistent on the Go side — the brain owns all "
      "looping, parallel dispatch and state.">>.

-spec phase_hint(phase() | atom()) -> binary().
phase_hint(first_turn) ->
    util:u(
        "这是本轮会话的首次推理。"
        "先理解用户意图，再决定是否调用工具；"
        "若信息已足够，可直接给出最终回答。");
phase_hint(after_tool_error) ->
    util:u(
        "上一轮工具执行失败或返回错误。"
        "请阅读 tool 消息中的错误信息，修正参数或换用其他工具，"
        "不要重复相同的无效调用。");
phase_hint(after_bridge_disconnect) ->
    util:u(
        "上一轮因 Bridge 断连或超时中断。"
        "请向用户简要说明情况，并尝试用已有上下文继续回答，"
        "或给出可执行的下一步建议。");
phase_hint(near_loop_limit) ->
    util:u(
        "ReAct 循环已接近上限。"
        "请尽快给出最终答案，避免再发起新的工具调用。");
phase_hint(thinking) ->
    <<>>;
phase_hint(_) ->
    <<>>.
