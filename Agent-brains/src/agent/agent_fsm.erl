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
%%
%% 失败案例记忆 (Task 1):
%%   thinking(enter) 前经 case_store:query 拿最近 5 条失败案例, 经
%%   context_assembler 注入 System Prompt 作"负面案例", 让 LLM 少踩坑。
%%   5 个失败点 (工具失败/循环耗尽×2/断连×2) 经 record_case/1 写入 case_store,
%%   防御性调用 —— case_store 不可用不阻断主流程。
%%====================================================================

%% 对外接口
-export([start_link/1, start/2, status/1]).
%% gen_statem 回调
-export([init/1, callback_mode/0, terminate/3, code_change/4]).
%% 状态函数 (observing 逻辑已内联到 acting, 不再单独设状态)
-export([idle/3, thinking/3, acting/3]).

%% ReAct 循环上限: 防止 LLM 在 acting<->thinking 间无限震荡
-define(MAX_LOOPS, 10).
%% 失败案例注入条数 (System Prompt 末尾的"负面案例"段)
-define(CASE_INJECT_LIMIT, 5).
%% history 超过此条数时在 thinking 中触发中期摘要（见 memory_summarizer）
-define(SUMMARY_HISTORY_THRESHOLD, 20).

-record(data, {
    session_id :: binary(),
    model :: binary(),
    session_prompt = <<>> :: binary(),
    api_key = <<>> :: binary(),
    api_base = <<>> :: binary(),
    %% 统一能力描述列表 (兼容旧 ToolDesc): #{name, description, parameters_json, kind, source, ...}
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

%% 查询 FSM 当前状态 (供 panel_server 经 sys:get_state 读, 返回 map 给前端)
%% 返回: #{state => idle|thinking|acting, loop_count, max_loops, history_len}
status(Pid) ->
    case sys:get_state(Pid, 5000) of
        {StateName, #data{loop_count = Loop, max_loops = Max, history = Hist}}
          when StateName =:= idle; StateName =:= thinking; StateName =:= acting ->
            #{state => StateName,
              loop_count => Loop,
              max_loops => Max,
              history_len => length(Hist)};
        Other ->
            #{state => unknown, raw => Other}
    end.

%%%===================================================================
%%% gen_statem 回调
%%%===================================================================

init(Args) ->
    SessionId = proplists:get_value(session_id, Args, <<>>),
    Model = proplists:get_value(model, Args, <<"gpt-4">>),
    Tools = proplists:get_value(tools, Args, []),
    History0 = proplists:get_value(history, Args, []),
    SessionPrompt = proplists:get_value(session_prompt, Args, <<>>),
    ApiKey = proplists:get_value(api_key, Args, <<>>),
    ApiBase = proplists:get_value(api_base, Args, <<>>),
    ok = state_store:register_session(SessionId, self()),
    case load_recovered_snapshot(SessionId, Model, Tools, History0, SessionPrompt, ApiKey, ApiBase) of
        {ok, StateName, Data} ->
            lager:info("agent_fsm resume session_id=~p state=~p loop=~p/~p history_len=~p",
                       [SessionId, StateName, Data#data.loop_count,
                        Data#data.max_loops, length(Data#data.history)]),
            {ok, StateName, Data};
        fresh ->
            lager:info("agent_fsm fresh start, session_id=~p", [SessionId]),
            Data = #data{session_id = SessionId,
                         model = Model,
                         tools = Tools,
                         history = History0,
                         session_prompt = SessionPrompt,
                         api_key = ApiKey,
                         api_base = ApiBase,
                         max_loops = ?MAX_LOOPS},
            {ok, idle, Data}
    end.

%% 从 state_store 恢复快照; 无快照则走全新会话。
load_recovered_snapshot(SessionId, Model, Tools, History0, SessionPrompt, ApiKey, ApiBase) ->
    case state_store:get_snapshot(SessionId) of
        {ok, {StateName, #data{} = Saved}}
          when StateName =:= idle; StateName =:= thinking; StateName =:= acting ->
            {ok, StateName, sanitize_recovered(Saved, Model, Tools, History0, SessionPrompt, ApiKey, ApiBase)};
        {ok, #data{} = Saved} ->
            {ok, idle, sanitize_recovered(Saved, Model, Tools, History0, SessionPrompt, ApiKey, ApiBase)};
        not_found ->
            fresh
    end.

%% 恢复时清除已失效的异步引用; acting 保留 pending_tool_calls 以便 enter 重派发。
sanitize_recovered(Saved, Model, Tools, History0, SessionPrompt, ApiKey, ApiBase) ->
    Hist = case History0 of
               [] -> Saved#data.history;
               _ -> History0
           end,
    Prompt = case SessionPrompt of
                 <<>> -> Saved#data.session_prompt;
                 _ -> SessionPrompt
             end,
    Key = case ApiKey of
              <<>> -> Saved#data.api_key;
              _ -> ApiKey
          end,
    Base = case ApiBase of
               <<>> -> Saved#data.api_base;
               _ -> ApiBase
           end,
    SavedBase = Saved#data{
        model = Model,
        tools = Tools,
        history = Hist,
        session_prompt = Prompt,
        api_key = Key,
        api_base = Base,
        llm_ref = undefined,
        tool_results = #{}
    },
    case Saved#data.pending_tool_calls of
        TCs when TCs =/= [], Saved#data.pending_count > 0 ->
            SavedBase;
        _ ->
            SavedBase#data{pending_tool_calls = [], pending_count = 0}
    end.

callback_mode() ->
    %% state_functions: 用 StateName/3 函数处理事件
    %% state_enter: 进入新状态时自动触发 EventType=enter 的回调
    %%   (OTP 28 起 atom 名为 state_enter, 非 state_enter_calls)
    [state_functions, state_enter].

%%%===================================================================
%%% 状态: idle
%%%   等待会话启动; 或最终答案就绪后驻留 (会话结束)
%%%===================================================================
idle(enter, _OldState, Data) ->
    ok = snapshot(idle, Data),
    keep_state_and_data;
idle(cast, start, Data) ->
    lager:info("session started, session_id=~p, history_len=~p",
                [Data#data.session_id, length(Data#data.history)]),
    History = reload_history(Data#data.session_id, Data#data.history),
    {next_state, thinking, Data#data{history = History}};
idle(_EventType, _EventContent, _Data) ->
    %% 其余事件忽略 (容错)
    keep_state_and_data.

%%%===================================================================
%%% 状态: thinking
%%%   组装上下文 (System Prompt + 历史 + 工具描述 + 失败案例) -> 经 Bridge_Manager
%%%   异步发 LLMInferRequest -> 等待 {llm_response, Ref, Response}
%%%   Response = #{content, tool_calls, prompt_tokens, completion_tokens}
%%%===================================================================
thinking(enter, _OldState, Data) ->
    ok = snapshot(thinking, Data),
    %% 关键节点: 进入 thinking 状态 (ReAct 每一轮的起点)
    lager:info("thinking(enter) fired, model=~p, history_len=~p, loop=~p/~p",
                [Data#data.model, length(Data#data.history),
                 Data#data.loop_count, Data#data.max_loops]),
    %% 查询最近失败案例注入 System Prompt (负面案例记忆, Task 1)
    Cases = query_cases(),
    Summaries = query_session_summaries(Data#data.session_id),
    Snippets = query_memory_snippets(Data#data.session_id, Data#data.history),
    Phase = detect_prompt_phase(Data),
    SelectionCtx = #{
        history => Data#data.history,
        session_prompt => Data#data.session_prompt,
        loop_count => Data#data.loop_count,
        max_loops => Data#data.max_loops,
        prompt_phase => Phase
    },
    VisibleTools = capability_selector:select(Data#data.tools, SelectionCtx),
    HiddenTools = capability_selector:dropped(Data#data.tools, SelectionCtx),
    lager:info("capability_selector selected=~p hidden=~p",
               [[maps:get(name, T, <<>>) || T <- VisibleTools], HiddenTools]),
    maybe_schedule_mid_session_summary(Data#data.session_id, length(Data#data.history)),
    Req = context_assembler:build(Data#data.model, #{
        history => Data#data.history,
        tools => VisibleTools,
        failure_cases => Cases,
        session_summaries => Summaries,
        memory_snippets => Snippets,
        prompt_phase => Phase,
        session_prompt => Data#data.session_prompt
    }),
    Req1 = maybe_inject_session_creds(Req, Data),
    Ref = bridge_manager:call_llm(self(), Req1),
    lager:info("llm request dispatched, ref=~p", [Ref]),
    Data1 = Data#data{llm_ref = Ref},
    ok = snapshot(thinking, Data1),
    {keep_state, Data1};
thinking(cast, {llm_chunk, Ref, Chunk},
         #data{llm_ref = Ref} = Data) ->
    %% Task 4 流式: LLM 增量 chunk 透传到 panel_server, 推给前端
    %% Chunk = #{kind => llm_chunk, content, reasoning_content}
    panel_server:push_chunk(Data#data.session_id, #{
        content => maps:get(content, Chunk, <<>>),
        reasoning_content => maps:get(reasoning_content, Chunk, <<>>)
    }),
    {keep_state, Data};
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
    ok = snapshot(thinking, Data1),
    case {ToolCalls, Data1#data.loop_count >= Data1#data.max_loops} of
        {[], _NoTools} ->
            %% LLM 未要求工具调用 -> 视为最终答案, 会话结束
            lager:info("final answer ready, transitioning thinking -> idle"),
            %% Task 4: 推送 final 终态到前端 (告知流结束)
            panel_server:push_final(Data1#data.session_id, #{
                content => Content,
                prompt_tokens => maps:get(prompt_tokens, Response, 0),
                completion_tokens => maps:get(completion_tokens, Response, 0),
                loop_count => Data1#data.loop_count
            }),
            schedule_session_summary(Data1#data.session_id),
            {next_state, idle, Data1};
        {_ToolCalls, true} ->
            %% 仍有工具调用但已达循环上限 -> 强制结束 (防 Eino 控制权泄漏/死循环)
            lager:warning("max_loops reached (~p/~p) with tool_calls pending, forcing idle",
                           [Data1#data.loop_count, Data1#data.max_loops]),
            record_case(#{
                session_id => Data1#data.session_id,
                scenario => <<"loop_exhausted">>,
                attempted => <<>>,
                failure_reason => util:u("LLM 仍要求工具调用但已达循环上限"),
                lesson => util:u("在达到上限前给出最终答案, 减少工具往返")
            }),
            %% Task 4: 推送 stream_err 终态告知前端流被中断
            panel_server:push_stream_err(
                Data1#data.session_id,
                util:u("ReAct 循环达到上限, 已强制结束")),
            schedule_session_summary(Data1#data.session_id),
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
    %% 柔性降级 (架构文档 5.3 / Phase 3.2):
    %% Go 侧断连, 本轮 LLM 推理无法完成。把"中断"作为 Observation 喂给 LLM,
    %% 让 LLM 决定道歉/重试/换路径, 而非直接结束会话。
    %% loop_count +1 防止断连反复重试导致死循环。
    lager:warning("bridge_disconnect in thinking, feeding as observation to LLM"),
    record_case(#{
        session_id => Data#data.session_id,
        scenario => <<"bridge_disconnect">>,
        attempted => <<>>,
        failure_reason => util:u("Bridge 断连, LLM 推理中断"),
        lesson => util:u("Bridge 不稳定时减少请求或换路径")
    }),
    %% Task 4: 这一轮 LLM 推理中断, 不立即给前端推 stream_err
    %% (因为 continue_after_observe 可能回 thinking 再发起新一轮 LLM 调用, 流未真正结束)
    ObsMsg = #{role => <<"system">>,
               content => <<"Bridge disconnected during LLM inference. "
                            "Please retry the request or adjust strategy.">>},
    Data1 = append_observation(Data, ObsMsg),
    continue_after_observe(Data1#data{llm_ref = undefined});
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
    ok = snapshot(acting, Data),
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
    %% 柔性降级 (架构文档 5.3 / Phase 3.2):
    %% Go 侧断连, 本轮工具执行中断。对每个未收结果的 pending_tool_call
    %% 生成 error observation, 全部当作工具失败喂给 LLM, 让 LLM 决定下一步。
    %% 已收的部分结果保留, 未收的标记为 interrupted。
    lager:warning("bridge_disconnect in acting, marking ~p pending tools as interrupted",
                   [length(Data#data.pending_tool_calls) - map_size(Data#data.tool_results)]),
    Interrupted = [TC || TC <- Data#data.pending_tool_calls,
                         not maps:is_key(maps:get(id, TC, <<>>),
                                         Data#data.tool_results)],
    FailedMsgs = [tool_msg(TC,
                           #{result_json => <<>>,
                             error => <<"bridge disconnected, tool execution interrupted">>})
                  || TC <- Interrupted],
    %% 记录断连案例 (Task 1): 每个中断的工具一条
    lists:foreach(fun(TC) ->
        record_case(#{
            session_id => Data#data.session_id,
            tool_name => maps:get(name, TC, <<>>),
            scenario => <<"bridge_disconnect">>,
            attempted => maps:get(arguments, TC, <<>>),
            failure_reason => util:u("Bridge 断连, 工具执行中断"),
            lesson => util:u("Bridge 不稳定时减少工具调用或换路径")
        })
    end, Interrupted),
    Data1 = lists:foldl(fun(M, D) -> append_observation(D, M) end,
                        Data, FailedMsgs),
    continue_after_observe(Data1#data{pending_tool_calls = [],
                                      tool_results = #{},
                                      pending_count = 0});
acting(_EventType, _EventContent, _Data) ->
    keep_state_and_data.

%%%===================================================================
%%% 内部函数
%%%===================================================================

%% 观察并决定下一步: 将工具结果追加进历史, 然后调公共的 continue_after_observe。
%% 由 acting 状态在收齐所有工具结果后调用 (非 enter 回调, 可自由返回 {next_state, ...})。
observe_and_transition(Data) ->
    %% 按 pending_tool_calls 顺序生成 tool 角色消息 (tool_call_id 与结果一一对应)
    ToolMsgs = [tool_msg(TC, maps:get(maps:get(id, TC, <<>>),
                                      Data#data.tool_results,
                                      #{result_json => <<>>, error => <<>>}))
                || TC <- Data#data.pending_tool_calls],
    %% 记录失败案例 (Task 1): 对每个 error 非空的工具调用写一条 tool_failed 案
    lists:foreach(fun(TC) ->
        Id = maps:get(id, TC, <<>>),
        Resp = maps:get(Id, Data#data.tool_results, #{}),
        case maps:get(error, Resp, <<>>) of
            Err when Err =/= <<>> ->
                record_case(#{
                    session_id => Data#data.session_id,
                    tool_name => maps:get(name, TC, <<>>),
                    scenario => <<"tool_failed">>,
                    attempted => maps:get(arguments, TC, <<>>),
                    failure_reason => Err,
                    lesson => util:u("检查参数格式或换用其他工具")
                });
            _ -> ok
        end
    end, Data#data.pending_tool_calls),
    Data1 = lists:foldl(fun(M, D) -> append_observation(D, M) end, Data, ToolMsgs),
    continue_after_observe(Data1#data{tool_results = #{},
                                      pending_tool_calls = [],
                                      pending_count = 0}).

%% 公共: 观察后的循环上限判断与下一步。
%% 由 observe_and_transition (工具收齐) 和 bridge_disconnect (柔性降级) 共用。
%% 行为: loop_count+1 -> 落快照 -> 判断上限 -> 回 thinking 让 LLM 决定 或 回 idle 强制结束。
continue_after_observe(Data0) ->
    NewCount = Data0#data.loop_count + 1,
    Data = Data0#data{loop_count = NewCount},
    ok = snapshot(thinking, Data),
    case NewCount >= Data#data.max_loops of
        true ->
            lager:warning("continue_after_observe: loop_count=~p >= max_loops=~p, forcing idle",
                          [NewCount, Data#data.max_loops]),
            record_case(#{
                session_id => Data#data.session_id,
                scenario => <<"loop_exhausted">>,
                attempted => <<>>,
                failure_reason => util:u("ReAct 循环达到上限"),
                lesson => util:u("减少工具往返次数, 避免重复调用")
            }),
            %% Task 4: 推送 stream_err 终态告知前端流被中断
            panel_server:push_stream_err(
                Data#data.session_id,
                util:u("ReAct 循环达到上限, 已强制结束")),
            {next_state, idle, Data};
        false ->
            lager:info("continue_after_observe: loop=~p/~p, back to thinking for LLM to decide",
                       [NewCount, Data#data.max_loops]),
            {next_state, thinking, Data}
    end.

%% 追加一条 Observation 消息到 history (本地 + state_store 双写)
append_observation(Data, Msg) ->
    NewHistory = Data#data.history ++ [Msg],
    state_store:append_history(Data#data.session_id, Msg),
    Data#data{history = NewHistory}.

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

%% 落快照到 ETS (崩溃恢复用): {StateName, #data{}} 供 transient 重启后续跑
snapshot(StateName, Data) when StateName =:= idle; StateName =:= thinking; StateName =:= acting ->
    state_store:put_snapshot(Data#data.session_id, {StateName, Data}),
    state_store:put_status(Data#data.session_id, #{
        state => StateName,
        loop_count => Data#data.loop_count,
        max_loops => Data#data.max_loops,
        history_len => length(Data#data.history)
    }),
    ok.

%% 查询最近失败案例注入 System Prompt (防御性: case_store 不可用则返回 [])
query_cases() ->
    try case_store:query(#{limit => ?CASE_INJECT_LIMIT}) of
        {ok, Cases} -> Cases;
        {error, _} -> []
    catch _:_ -> []
    end.

query_session_summaries(SessionId) ->
    try memory_summarizer:get_recent(SessionId, 3) of
        {ok, Summaries} -> Summaries;
        {error, _} -> []
    catch _:_ -> []
    end.

query_memory_snippets(SessionId, History) ->
    try memory_rag:prefetch(SessionId, History) of
        Snippets when is_list(Snippets) -> Snippets;
        _ -> []
    catch _:_ -> []
    end.

reload_history(SessionId, Fallback) ->
    case state_store:get_history(SessionId) of
        {ok, H} when H =/= [] -> H;
        _ -> Fallback
    end.

schedule_session_summary(SessionId) ->
    try memory_summarizer:schedule(SessionId)
    catch _:_ -> ok
    end.

maybe_schedule_mid_session_summary(SessionId, Len)
  when is_integer(Len), Len >= ?SUMMARY_HISTORY_THRESHOLD ->
    try memory_summarizer:schedule_if_long(SessionId)
    catch _:_ -> ok
    end;
maybe_schedule_mid_session_summary(_SessionId, _Len) ->
    ok.

detect_prompt_phase(#data{loop_count = 0}) ->
    first_turn;
detect_prompt_phase(#data{loop_count = LC, max_loops = Max})
  when is_integer(LC), is_integer(Max), LC >= Max - 1 ->
    near_loop_limit;
detect_prompt_phase(#data{history = Hist}) ->
    case recent_observation_kind(Hist) of
        bridge_disconnect -> after_bridge_disconnect;
        tool_error -> after_tool_error;
        _ -> thinking
    end.

recent_observation_kind(History) when is_list(History) ->
    case lists:reverse(History) of
        [#{role := <<"system">>, content := C}|_] ->
            case binary:match(C, <<"Bridge disconnected">>) of
                nomatch -> thinking;
                _ -> bridge_disconnect
            end;
        [#{role := <<"tool">>, content := C}|_] ->
            case looks_like_tool_error(C) of
                true -> tool_error;
                false -> thinking
            end;
        _ ->
            thinking
    end.

looks_like_tool_error(Content) when is_binary(Content) ->
    Content =/= <<>> andalso
        (binary:match(Content, <<"error">>) =/= nomatch orelse
         binary:match(Content, <<"bridge disconnected">>) =/= nomatch orelse
         binary:match(Content, <<"not found">>) =/= nomatch);
looks_like_tool_error(_) ->
    false.

maybe_inject_session_creds(Req, #data{api_key = <<>>}) ->
    Req;
maybe_inject_session_creds(Req, #data{api_key = Key, api_base = Base}) ->
    Req#{api_key => Key, api_base => Base}.

%% 记录失败案例 (防御性: 写入失败不阻断 FSM 主流程)
record_case(CaseMap) ->
    try case_store:record(CaseMap) of
        ok -> ok;
        {error, _} -> ok
    catch _:_ -> ok
    end.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.
