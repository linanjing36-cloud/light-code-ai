-module(agent_fsm).
-behaviour(gen_statem).

%%====================================================================
%% Agent_FSM —— ReAct 编排核心 (gen_statem)
%%====================================================================
%%
%% 编排哲学 / Eino 控制权泄漏禁令:
%%   Agent-brains 是 Hermes 系统唯一的控制中心。所有"思考-行动-观察"循环、
%%   上下文组装、并行工具派发、故障恢复都由本模块掌握。
%%   Go 侧 Eion-tools 严禁持有任何循环/状态 —— 它只接受一次原子请求
%%   (LLMInferRequest 或 ToolExecRequest), 返回一次响应, 即结束。
%%   任何让 Go 侧自行多轮调用、自行决定下一步的写法都视为"控制权泄漏",
%%   必须在此 FSM 内显式闭环。
%%
%% 三个状态 (observing 逻辑内联到 acting 的事件处理, 不单独设状态):
%%   idle      —— 等待会话启动; 或最终答案就绪后回到此态
%%   thinking  —— 组装上下文 -> 异步发 LLMInferRequest -> 等响应
%%   acting    —— 解析 tool_calls, 并行派发 ToolExecRequest, 收齐结果后
%%                将 observation 追加进历史, 计数+1, 判断循环上限
%%
%% 循环上限: ?MAX_LOOPS (默认 10), 防止 LLM 死循环耗尽资源。
%%====================================================================

%% 对外接口
-export([start_link/1, start/2]).
%% gen_statem 回调
-export([init/1, callback_mode/0, terminate/3, code_change/4]).
%% 状态函数 (observing 逻辑已内联到 acting, 不再单独设状态)
-export([idle/3, thinking/3, acting/3]).

%% ReAct 循环上限: 防止 LLM 在 acting<->thinking 间无限震荡
-define(MAX_LOOPS, 10).

-record(data, {
    session_id :: binary(),
    model :: binary(),
    %% 工具描述列表 (ToolDesc map): #{name, description, parameters_json}
    tools = [] :: [map()],
    %% 对话历史 (Message map): #{role, content, tool_calls, tool_call_id}
    history = [] :: [map()],
    loop_count = 0 :: non_neg_integer(),
    max_loops = ?MAX_LOOPS :: non_neg_integer(),
    %% 当前轮 LLM 要求执行的工具调用 (ToolCall map): #{id, name, arguments}
    pending_tool_calls = [] :: [map()],
    %% 当前轮已收工具结果: tool_call.id => ToolExecResponse map
    tool_results = #{} :: #{binary() => map()},
    %% 本轮期望收到的工具结果数
    pending_count = 0 :: non_neg_integer(),
    %% LLM 异步请求引用 (匹配响应)
    llm_ref :: reference() | undefined
}).

%%%===================================================================
%%% 对外接口
%%%===================================================================

start_link(Args) ->
    gen_statem:start_link(?MODULE, Args, []).

%% 启动一次 ReAct 会话 (从 idle 进入 thinking)
start(Pid, _Opts) ->
    gen_statem:cast(Pid, start).

%%%===================================================================
%%% gen_statem 回调
%%%===================================================================

init(Args) ->
    SessionId = proplists:get_value(session_id, Args, <<>>),
    Model = proplists:get_value(model, Args, <<"gpt-4">>),
    Tools = proplists:get_value(tools, Args, []),
    History = proplists:get_value(history, Args, []),
    Data = #data{session_id = SessionId,
                 model = Model,
                 tools = Tools,
                 history = History,
                 max_loops = ?MAX_LOOPS},
    %% 启动即停留在 idle, 等待外部 start 触发主循环
    {ok, idle, Data}.

callback_mode() ->
    %% state_functions: 用 StateName/3 函数处理事件
    %% state_enter: 进入新状态时自动触发 EventType=enter 的回调
    %%   (OTP 28 起 atom 名为 state_enter, 非 state_enter_calls)
    [state_functions, state_enter].

%%%===================================================================
%%% 状态: idle
%%%   等待会话启动; 或最终答案就绪后驻留 (会话结束)
%%%===================================================================
idle(cast, start, Data) ->
    %% 关键节点: ReAct 主循环启动 (idle -> thinking)
    lager:info("session started, session_id=~p, history_len=~p",
                [Data#data.session_id, length(Data#data.history)]),
    ok = snapshot(Data),
    {next_state, thinking, Data};
idle(_EventType, _EventContent, _Data) ->
    %% 其余事件忽略 (容错)
    keep_state_and_data.

%%%===================================================================
%%% 状态: thinking
%%%   组装上下文 (System Prompt + 历史 + 工具描述) -> 经 Bridge_Manager
%%%   异步发 LLMInferRequest -> 等待 {llm_response, Ref, Response}
%%%   Response = #{content, tool_calls, prompt_tokens, completion_tokens}
%%%===================================================================
thinking(enter, _OldState, Data) ->
    %% 关键节点: 进入 thinking 状态 (ReAct 每一轮的起点)
    lager:info("thinking(enter) fired, model=~p, history_len=~p, loop=~p/~p",
                [Data#data.model, length(Data#data.history),
                 Data#data.loop_count, Data#data.max_loops]),
    Req = context_assembler:build(Data#data.model, #{
        history => Data#data.history,
        tools => Data#data.tools
    }),
    lager:debug("calling bridge_manager:call_llm"),
    %% 异步投递 (经 pb_codec 编码为 Protobuf 二进制后发往 Go 侧)
    Ref = bridge_manager:call_llm(self(), Req),
    lager:info("llm request dispatched, ref=~p", [Ref]),
    {keep_state, Data#data{llm_ref = Ref}};
thinking(cast, {llm_response, Ref, Response},
         #data{llm_ref = Ref} = Data) ->
    %% 关键节点: LLM 响应回链 (可能是含 tool_calls 的中间轮, 也可能是最终答案)
    Content = maps:get(content, Response, <<>>),
    ToolCalls = maps:get(tool_calls, Response, []),
    lager:info("llm_response received, content_size=~p, tool_calls=~p, prompt_tokens=~p",
                [byte_size(Content), length(ToolCalls),
                 maps:get(prompt_tokens, Response, 0)]),
    AssistantMsg = #{role => <<"assistant">>,
                     content => Content,
                     tool_calls => ToolCalls},
    History = Data#data.history ++ [AssistantMsg],
    %% 同步到 state_store 的 history (供外部轮询, 如 agent_demo:wait_idle)
    state_store:append_history(Data#data.session_id, AssistantMsg),
    Data1 = Data#data{history = History},
    ok = snapshot(Data1),
    case {ToolCalls, Data1#data.loop_count >= Data1#data.max_loops} of
        {[], _NoTools} ->
            %% LLM 未要求工具调用 -> 视为最终答案, 会话结束
            lager:info("final answer ready, transitioning thinking -> idle"),
            {next_state, idle, Data1};
        {_ToolCalls, true} ->
            %% 仍有工具调用但已达循环上限 -> 强制结束 (防 Eino 控制权泄漏/死循环)
            lager:warning("max_loops reached (~p/~p) with tool_calls pending, forcing idle",
                           [Data1#data.loop_count, Data1#data.max_loops]),
            {next_state, idle, Data1};
        {ToolCalls, false} ->
            %% 进入执行阶段: 并行派发
            lager:info("dispatching ~p tool_calls, entering acting",
                       [length(ToolCalls)]),
            {next_state, acting,
             Data1#data{pending_tool_calls = ToolCalls,
                        tool_results = #{},
                        pending_count = length(ToolCalls)}}
    end;
thinking(cast, {bridge_disconnect}, Data) ->
    %% Go 侧断连: 本轮推理无法完成, 落快照后回 idle
    ok = snapshot(Data),
    {next_state, idle, Data};
thinking(_EventType, _EventContent, _Data) ->
    keep_state_and_data.

%%%===================================================================
%%% 状态: acting
%%%   并行派发 ToolExecRequest (每个 ToolCall 一条请求, 各自 req_id = tool_call.id)
%%%   结果以 {tool_result, ToolCallId, Resp} 异步回投, 收齐后:
%%%     将结果作为 observation 追加进历史, 计数+1, 判断循环上限,
%%%     决定回 thinking 继续 ReAct 还是回 idle 强制结束。
%%%
%%%   注意: gen_statem 的 enter 回调不能返回 {next_state, ...} 也不能用
%%%   {next_event, ...} 动作, 所以观察逻辑直接内联在 acting 的事件处理中,
%%%   不再单独设置 observing 状态。
%%%===================================================================
acting(enter, _OldState, Data) ->
    ToolCalls = Data#data.pending_tool_calls,
    %% 关键节点: 进入 acting 状态, 派发工具调用
    lager:info("acting(enter) fired, dispatching ~p tools, pending_count=~p",
                [length(ToolCalls), Data#data.pending_count]),
    %% 并行派发: bridge_manager 内部对每个 ToolCall spawn 一条异步调用
    bridge_manager:call_tool_batch(self(), ToolCalls),
    {keep_state, Data};
acting(cast, {tool_result, ToolCallId, Resp}, Data) ->
    Results = maps:put(ToolCallId, Resp, Data#data.tool_results),
    lager:debug("tool_result received, tool_call_id=~p, collected=~p/~p",
                [ToolCallId, map_size(Results), Data#data.pending_count]),
    case map_size(Results) >= Data#data.pending_count of
        true ->
            %% 本轮全部工具结果已收齐 -> 观察并决定下一步
            observe_and_transition(Data#data{tool_results = Results});
        false ->
            {keep_state, Data#data{tool_results = Results}}
    end;
acting(cast, {bridge_disconnect}, Data) ->
    %% Go 侧断连: 已收的部分结果丢弃, 落快照后回 idle
    ok = snapshot(Data),
    {next_state, idle, Data};
acting(_EventType, _EventContent, _Data) ->
    keep_state_and_data.

%%%===================================================================
%%% 内部函数
%%%===================================================================

%% 观察并决定下一步: 将工具结果追加进历史, 循环计数+1, 判断上限。
%% 由 acting 状态在收齐所有工具结果后调用 (非 enter 回调, 可自由返回 {next_state, ...})。
observe_and_transition(Data) ->
    NewCount = Data#data.loop_count + 1,
    %% 按 pending_tool_calls 顺序生成 tool 角色消息 (tool_call_id 与结果一一对应)
    ToolMsgs = [tool_msg(TC, maps:get(maps:get(id, TC, <<>>),
                                      Data#data.tool_results, #{result_json => <<>>, error => <<>>}))
                || TC <- Data#data.pending_tool_calls],
    NewHistory = Data#data.history ++ ToolMsgs,
    %% 同步 tool 角色消息到 state_store (供外部轮询)
    lists:foreach(fun(TM) -> state_store:append_history(Data#data.session_id, TM) end, ToolMsgs),
    NewData = Data#data{loop_count = NewCount,
                        history = NewHistory,
                        tool_results = #{},
                        pending_tool_calls = [],
                        pending_count = 0},
    ok = snapshot(NewData),
    case NewCount >= NewData#data.max_loops of
        true ->
            %% 超过循环上限 -> 强制结束
            lager:warning("observe: loop_count=~p >= max_loops=~p, forcing idle",
                          [NewCount, NewData#data.max_loops]),
            {next_state, idle, NewData};
        false ->
            %% 继续 ReAct 循环
            lager:info("observe: tool results appended, loop=~p/~p, back to thinking",
                       [NewCount, NewData#data.max_loops]),
            {next_state, thinking, NewData}
    end.

%% 由 ToolCall + ToolExecResponse 构造一条 tool 角色消息
%% 与 hermes.proto 的 Message{role, content, tool_calls, tool_call_id} 对齐
tool_msg(#{id := Id} = _ToolCall, Resp) ->
    %% error 非空表示执行失败; 此时 content 记录错误, 否则记 result_json
    case maps:get(error, Resp, <<>>) of
        Err when Err =/= <<>> ->
            #{role => <<"tool">>, content => Err, tool_call_id => Id};
        _ ->
            #{role => <<"tool">>,
              content => maps:get(result_json, Resp, <<>>),
              tool_call_id => Id}
    end;
tool_msg(_ToolCall, Resp) ->
    #{role => <<"tool">>, content => maps:get(result_json, Resp, <<>>)}.

%% 落快照到 ETS (崩溃恢复用): state_store 持有 session -> #data{} 映射
snapshot(Data) ->
    state_store:put_snapshot(Data#data.session_id, Data),
    ok.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_Vsn, State, Data, _Extra) ->
    {ok, State, Data}.
