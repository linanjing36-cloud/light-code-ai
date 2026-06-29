-module(planner_chain).

%%====================================================================
%% Planner_Chain —— 计划-校验-批评链 (EXEC-P2-001)
%%
%% 单次 LLM 调用完成三阶段推理 (plan → self-verify → self-critique),
%% 再本地校验工具可用性。避免多次 roundtrip 延迟首 token。
%%
%% 触发条件 (should_plan/2):
%%   - 首轮对话 (loop_count=0)
%%   - 无待处理工具调用
%%   - 用户消息判定为复杂任务
%%
%% 与 FSM 集成:
%%   - thinking(enter) 时如 should_plan 为 true, 同步调用 run/3 获取计划
%%   - 计划结果注入 system prompt (section: ## 执行计划)
%%   - 超时或失败时返回 {skip, _} (不影响正常 ReAct 流程)
%%====================================================================

-export([run/3,
         run_with_plan/3,
         should_plan/2]).

-define(CHAIN_TIMEOUT, 20000).

%%====================================================================
%% API
%%====================================================================

%% 判断是否需要触发计划链
-spec should_plan(binary(), map()) -> boolean().
should_plan(UserMsg, Ctx) when is_binary(UserMsg) ->
    LoopCount = maps:get(loop_count, Ctx, 0),
    HasToolCalls = maps:get(has_tool_calls, Ctx, false),
    if
        LoopCount =/= 0 -> false;
        HasToolCalls -> false;
        true -> is_complex_task(UserMsg)
    end;
should_plan(_, _) -> false.

%% 执行计划链
%% 返回 {ok, PlanBinary} | {skip, Reason}
-spec run(binary(), [map()], [map()]) -> {ok, binary()} | {skip, term()}.
run(UserMsg, History, AvailableTools) ->
    ToolNames = [maps:get(name, T, <<>>) || T <- AvailableTools],
    ToolList = iolist_to_binary(lists:join(<<", ">>, ToolNames)),
    UserCtx = recent_user_context(History),
    SysPrompt = build_system_prompt(ToolList),
    UserContent = build_user_content(UserMsg, UserCtx),
    Messages = [
        #{role => <<"system">>, content => SysPrompt},
        #{role => <<"user">>, content => UserContent}
    ],
    case call_llm_sync(Messages) of
        {ok, Content} ->
            case parse_and_validate(Content, AvailableTools) of
                {ok, PlanBin, _PlanMap} -> {ok, PlanBin};
                {skip, Reason} -> {skip, Reason};
                {error, Reason} -> {skip, Reason}
            end;
        {error, Reason} ->
            {skip, Reason}
    end.

%% 执行计划链, 同时返回格式化文本(用于注入 prompt)和结构化计划(用于前端推送)
%% 返回 {ok, PlanBinary, PlanMap} | {skip, Reason}
%% PlanMap = #{goal => binary(), steps => [#{index, description, tool_hint, risk_level}],
%%            warnings => [binary()], suggestions => [binary()]}
-spec run_with_plan(binary(), [map()], [map()]) -> {ok, binary(), map()} | {skip, term()}.
run_with_plan(UserMsg, History, AvailableTools) ->
    ToolNames = [maps:get(name, T, <<>>) || T <- AvailableTools],
    ToolList = iolist_to_binary(lists:join(<<", ">>, ToolNames)),
    UserCtx = recent_user_context(History),
    SysPrompt = build_system_prompt(ToolList),
    UserContent = build_user_content(UserMsg, UserCtx),
    Messages = [
        #{role => <<"system">>, content => SysPrompt},
        #{role => <<"user">>, content => UserContent}
    ],
    case call_llm_sync(Messages) of
        {ok, Content} ->
            case parse_and_validate(Content, AvailableTools) of
                {ok, PlanBin, PlanMap} -> {ok, PlanBin, PlanMap};
                {error, Reason} -> {skip, Reason}
            end;
        {error, Reason} ->
            {skip, Reason}
    end.

%%====================================================================
%% 复杂度判定
%%====================================================================

is_complex_task(Msg) ->
    Size = byte_size(Msg),
    HasComplexKeyword = lists:any(fun(Kw) ->
        binary:match(Msg, Kw) =/= nomatch
    end, complex_keywords()),
    HasMultiStep = binary:match(Msg, <<"首先">>) =/= nomatch
        orelse binary:match(Msg, <<"然后">>) =/= nomatch
        orelse binary:match(Msg, <<"接着">>) =/= nomatch
        orelse binary:match(Msg, <<"同时">>) =/= nomatch
        orelse binary:match(Msg, <<"并且">>) =/= nomatch,
    Size > 80 orelse HasComplexKeyword orelse HasMultiStep.

complex_keywords() ->
    [util:u(K) || K <- [
        "规划", "实现", "设计", "开发", "修复", "重构",
        "搭建", "创建", "编写", "集成", "配置", "部署",
        "计划", "方案", "架构", "分析", "排查", "调试",
        "添加", "新增", "修改", "优化", "迁移",
        "plan", "implement", "design", "build", "fix",
        "refactor", "create", "develop", "debug", "add"
    ]].

%%====================================================================
%% 同步 LLM 调用
%%====================================================================
%% 注意: bridge_manager:call_llm 通过 gen_statem:cast 回投,
%% 在 gen_server/gen_statem 回调中同步 receive 需匹配 '$gen_cast' 包装。
%% 调用方需在自身进程上下文中执行 (由 agent_fsm:thinking(enter) 直接调用,
%% 此时 gen_statem 正处于回调执行中, 我们可以"窃取"一条消息然后返回,
%% 不影响后续事件循环——因为使用独立 Ref 且有精确匹配)。

call_llm_sync(Messages) ->
    Model = application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>),
    Req = #{
        model => Model,
        stream => false,
        tools => [],
        messages => Messages
    },
    case whereis(bridge_manager) of
        undefined -> {error, bridge_down};
        _ ->
            Ref = bridge_manager:call_llm(self(), Req),
            TRef = erlang:send_after(?CHAIN_TIMEOUT, self(), {chain_timeout, Ref}),
            Result = receive_llm_response(Ref, ?CHAIN_TIMEOUT + 2000),
            erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
            Result
    end.

receive_llm_response(Ref, Timeout) ->
    receive
        {'$gen_cast', {llm_response, Ref, Resp}} ->
            {ok, maps:get(content, Resp, <<>>)};
        {chain_timeout, Ref} ->
            {error, timeout}
    after Timeout ->
        {error, timeout}
    end.

%%====================================================================
%% Prompt 构建
%%====================================================================

build_system_prompt(ToolList) ->
    util:u(
        "你是任务规划与校验专家。对用户的复杂任务进行分析规划、自我校验和批评审视, 输出执行计划。\n\n"
        "输出严格 JSON, 格式:\n"
        "{\"goal\":\"一句话描述最终目标\","
        "\"steps\":[{\"index\":1,\"action\":\"具体步骤描述\","
        "\"tool\":\"工具名或none\",\"expected\":\"预期产出\","
        "\"risk\":\"低|中|高\",\"note\":\"注意事项(可选)\"}],"
        "\"warnings\":[\"需要注意的风险或约束\"],"
        "\"assumptions\":[\"已做出的假设\"]}\n\n"
        "规则:\n"
        "1. 步骤不超过 6 步, 聚焦核心路径, 避免冗余\n"
        "2. tool 字段: 需要工具时填写工具名, 不需要填 'none'\n"
        "3. 可用工具: ") ++ binary_to_list(ToolList) ++
        "\n4. risk 标注: 高=删除/覆盖/外部写入; 中=代码修改; 低=只读/回答\n"
        "5. warnings 列出关键约束(如信息不足、权限要求、潜在风险)\n"
        "6. assumptions 列出已做的假设(如环境、依赖)\n"
        "7. 先自我校验: 每步是否有可用工具支撑, 信息是否充分\n"
        "8. 再自我审视: 是否有遗漏路径, 是否有更优方案\n"
        "9. 只输出 JSON, 不要 Markdown 代码块标记, 不要解释".

build_user_content(UserMsg, <<>>) ->
    iolist_to_binary([<<"用户请求: ">>, UserMsg]);
build_user_content(UserMsg, Ctx) ->
    iolist_to_binary([Ctx, <<"\n\n当前请求: ">>, UserMsg]).

recent_user_context(History) ->
    UserMsgs = [C || #{role := <<"user">>, content := C} <- History,
                      is_binary(C), C =/= <<>>],
    case lists:reverse(UserMsgs) of
        [Last | _] when byte_size(Last) > 20 ->
            iolist_to_binary([<<"近期上下文: ">>, Last]);
        _ ->
            <<>>
    end.

%%====================================================================
%% 解析 + 本地校验
%%====================================================================

parse_and_validate(Content, AvailableTools) ->
    JsonText = extract_json(Content),
    try
        Map = decode_json(JsonText),
        case is_map(Map) andalso maps:is_key(<<"steps">>, Map) of
            true ->
                Validated = local_verify(Map, AvailableTools),
                PlanBin = format_plan(Validated),
                PlanMap = build_plan_map(Validated),
                {ok, PlanBin, PlanMap};
            false ->
                {error, invalid_plan}
        end
    catch _:_ ->
        {error, parse_failed}
    end.

local_verify(Plan, AvailableTools) ->
    ToolSet = build_tool_set(AvailableTools),
    Steps = maps:get(<<"steps">>, Plan, []),
    VerifiedSteps = [verify_step(Step, ToolSet) || Step <- Steps],
    Plan#{<<"steps">> => VerifiedSteps}.

build_tool_set(Tools) ->
    lists:foldl(fun(T, Acc) ->
        sets:add_element(maps:get(name, T, <<>>), Acc)
    end, sets:new(), Tools).

verify_step(Step, ToolSet) ->
    Tool = to_bin(maps:get(<<"tool">>, Step, <<"none">>)),
    IsNoOp = lists:member(Tool, [<<"none">>, <<"direct">>, <<"answer">>, <<>>]),
    case IsNoOp orelse sets:is_element(Tool, ToolSet) of
        true -> Step;
        false ->
            Warning0 = maps:get(<<"note">>, Step, <<>>),
            WarnMsg = iolist_to_binary([
                <<"工具 ">>, Tool, <<" 当前不可用, 将通过其他方式完成或告知用户">>
            ]),
            Note = case Warning0 of
                <<>> -> WarnMsg;
                _ -> iolist_to_binary([Warning0, <<"; ">>, WarnMsg])
            end,
            Step#{<<"tool">> => <<"none">>, <<"note">> => Note}
    end.

%%====================================================================
%% 输出格式化 (注入 system prompt)
%%====================================================================

format_plan(Plan) ->
    Goal = to_bin(maps:get(<<"goal">>, Plan, <<>>)),
    Steps = maps:get(<<"steps">>, Plan, []),
    Warnings = maps:get(<<"warnings">>, Plan, []),
    Assumptions = maps:get(<<"assumptions">>, Plan, []),
    Header = util:u("## 执行计划 (请遵循此计划执行)\n"),
    Parts0 = [Header],
    Parts1 = case Goal of
        <<>> -> Parts0;
        _ -> [iolist_to_binary([<<"目标: ">>, Goal]) | Parts0]
    end,
    StepLines = lists:map(fun format_step/1, lists:sublist(Steps, 6)),
    Parts2 = Parts1 ++ StepLines,
    Parts3 = add_list_section(Parts2, Warnings, <<"⚠ 注意事项:">>),
    Parts4 = add_list_section(Parts3, Assumptions, <<"📌 假设:">>),
    iolist_to_binary(lists:join(<<"\n">>, lists:reverse(Parts4))).

format_step(Step) ->
    Idx = maps:get(<<"index">>, Step, 0),
    Action = to_bin(maps:get(<<"action">>, Step, <<>>)),
    Tool = to_bin(maps:get(<<"tool">>, Step, <<"none">>)),
    Risk = to_bin(maps:get(<<"risk">>, Step, <<"低">>)),
    Expected = to_bin(maps:get(<<"expected">>, Step, <<>>)),
    Note = to_bin(maps:get(<<"note">>, Step, <<>>)),
    ToolPart = case Tool of
        <<"none">> -> <<>>;
        <<>> -> <<>>;
        T -> iolist_to_binary([<<" [工具:">>, T, <<"]">>])
    end,
    RiskPart = case Risk of
        R when R =:= <<"高">> orelse R =:= <<"high">> -> <<" [HIGH RISK]">>;
        R when R =:= <<"中">> orelse R =:= <<"medium">> -> <<" [中风险]">>;
        _ -> <<>>
    end,
    ExpPart = case Expected of
        <<>> -> <<>>;
        E -> iolist_to_binary([<<"\n    → ">>, truncate(E, 120)])
    end,
    NotePart = case Note of
        <<>> -> <<>>;
        N -> iolist_to_binary([<<"\n    注: ">>, truncate(N, 120)])
    end,
    IdxBin = if
        is_integer(Idx) -> integer_to_binary(Idx);
        true -> <<"?">>
    end,
    iolist_to_binary([
        IdxBin, <<". ">>, truncate(Action, 200), ToolPart, RiskPart,
        ExpPart, NotePart
    ]).

add_list_section(Parts, [], _Header) ->
    Parts;
add_list_section(Parts, Items, Header) ->
    Lines = [iolist_to_binary([<<"  - ">>, to_bin(I)]) || I <- Items, is_binary(I) orelse is_list(I)],
    case Lines of
        [] -> Parts;
        _ -> lists:reverse([Header | lists:reverse(Lines)]) ++ Parts
    end.

%%====================================================================
%% 工具函数
%%====================================================================

extract_json(Content) ->
    case {binary:match(Content, <<"{">>), binary:match(Content, <<"}">>, [last])} of
        {{Start, _}, {End, _}} when End >= Start ->
            binary:part(Content, Start, End - Start + 1);
        _ -> Content
    end.

decode_json(Bin) ->
    case code:which(json) of
        non_existing -> #{};
        _ ->
            try json:decode(Bin)
            catch _:_ -> #{}
            end
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) ->
    try list_to_binary(L)
    catch _:_ -> iolist_to_binary(io_lib:format("~p", [L]))
    end;
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(_) -> <<>>.

truncate(Bin, Max) when is_binary(Bin), byte_size(Bin) > Max ->
    <<Bin:Max/binary, "..."/utf8>>;
truncate(Bin, _Max) when is_binary(Bin) ->
    Bin;
truncate(Other, _Max) ->
    to_bin(Other).

%%====================================================================
%% 构建前端推送用的结构化计划
%%====================================================================

build_plan_map(Plan) ->
    Goal = to_bin(maps:get(<<"goal">>, Plan, <<>>)),
    Steps0 = maps:get(<<"steps">>, Plan, []),
    Steps = [build_step_map(S) || S <- Steps0, is_map(S)],
    Warnings = [to_bin(W) || W <- maps:get(<<"warnings">>, Plan, []),
                             W =/= <<>>, W =/= []],
    Assumptions = [to_bin(A) || A <- maps:get(<<"assumptions">>, Plan, []),
                                A =/= <<>>, A =/= []],
    #{goal => Goal,
      steps => Steps,
      warnings => Warnings,
      suggestions => Assumptions}.

build_step_map(Step) ->
    Idx = maps:get(<<"index">>, Step, 0),
    Action = to_bin(maps:get(<<"action">>, Step, <<>>)),
    Tool = to_bin(maps:get(<<"tool">>, Step, <<"none">>)),
    Risk = to_bin(maps:get(<<"risk">>, Step, <<"低">>)),
    Expected = to_bin(maps:get(<<"expected">>, Step, <<>>)),
    Note = to_bin(maps:get(<<"note">>, Step, <<>>)),
    ToolHint = case Tool of
                   <<"none">> -> <<>>;
                   <<>> -> <<>>;
                   T -> T
               end,
    RiskLevel = case Risk of
                    R when R =:= <<"高">> orelse R =:= <<"high">> -> <<"high">>;
                    R when R =:= <<"中">> orelse R =:= <<"medium">> -> <<"medium">>;
                    _ -> <<"low">>
                end,
    #{index => Idx,
      description => Action,
      tool_hint => ToolHint,
      risk_level => RiskLevel,
      expected => Expected,
      note => Note}.
