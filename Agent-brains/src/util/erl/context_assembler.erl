-module(context_assembler).

-export([build/2, trim_history/2, filter_llm_history/1]).

-define(DEFAULT_MAX_HISTORY_MSGS, 40).

%%====================================================================
%% Context_Assembler —— 上下文组装器 (纯函数式, 无副作用)
%%====================================================================

-spec build(binary(), map()) -> map().
build(Model, Ctx) ->
    RawHistory = maps:get(history, Ctx, []),
    Tools = maps:get(tools, Ctx, []),
    Cases = maps:get(failure_cases, Ctx, []),
    Summaries = maps:get(session_summaries, Ctx, []),
    Snippets = maps:get(memory_snippets, Ctx, []),
    Phase = maps:get(prompt_phase, Ctx, thinking),
    SessionPrompt = maps:get(session_prompt, Ctx, <<>>),
    MaxHist = maps:get(max_history_msgs, Ctx, ?DEFAULT_MAX_HISTORY_MSGS),
    History = normalize_history(trim_history(filter_llm_history(RawHistory), MaxHist)),
    SysContent = system_prompt(Phase, SessionPrompt, Cases, Summaries, Snippets),
    Messages = [#{role => <<"system">>, content => SysContent} | History],
    #{
        model => Model,
        messages => Messages,
        tools => normalize_tools(Tools),
        stream => true
    }.

%% 去掉 history 中的 system 角色（统一由本模块生成一条 system 消息）
-spec filter_llm_history([map()]) -> [map()].
filter_llm_history(History) ->
    [M || M <- History, maps:get(role, M, <<>>) =/= <<"system">>].

%% 保留最近 Max 条消息（含 user/assistant/tool）
-spec trim_history([map()], pos_integer()) -> [map()].
trim_history(History, Max) when is_list(History), is_integer(Max), Max > 0 ->
    case length(History) =< Max of
        true -> History;
        false -> lists:nthtail(length(History) - Max, History)
    end;
trim_history(History, _Max) ->
    History.

system_prompt(Phase, SessionPrompt, Cases, Summaries, Snippets) ->
    Base = iolist_to_binary([prompt_templates:core(), phase_section(Phase)]),
    WithSession = append_section(Base, SessionPrompt, util:u("## 会话指令\n")),
    WithSum = append_list_section(WithSession, Summaries,
                                  util:u("## 会话摘要 (长期记忆)\n"),
                                  fun format_summaries/1),
    WithRag = append_list_section(WithSum, Snippets,
                                  util:u("## 相关记忆片段 (向量检索)\n"),
                                  fun format_snippets/1),
    append_list_section(WithRag, Cases,
                        util:u("## 负面案例 (避免重复踩坑)\n"),
                        fun format_cases/1).

phase_section(Phase) ->
    case prompt_templates:phase_hint(Phase) of
        <<>> -> <<>>;
        Hint -> iolist_to_binary([<<"\n\n">>, Hint])
    end.

append_section(Base, <<>>, _Header) ->
    iolist_to_binary(Base);
append_section(Base, Text, Header) when is_binary(Text), Text =/= <<>> ->
    iolist_to_binary([Base, <<"\n\n">>, Header, Text]);
append_section(Base, _, _) ->
    iolist_to_binary(Base).

append_list_section(Base, [], _Header, _Fmt) ->
    iolist_to_binary(Base);
append_list_section(Base, Items, Header, Fmt) when is_list(Items) ->
    iolist_to_binary([Base, <<"\n\n">>, Header, Fmt(Items)]).

format_snippets(Snippets) ->
    Lines = [format_snippet(S) || S <- Snippets],
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

format_snippet(#{content := Text}) when is_binary(Text), Text =/= <<>> ->
    iolist_to_binary([<<"- ">>, truncate(Text, 400)]);
format_snippet(_) ->
    <<>>.

format_summaries(Summaries) ->
    Lines = [format_summary(S) || S <- Summaries],
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

format_summary(#{text := Text}) when is_binary(Text), Text =/= <<>> ->
    iolist_to_binary([<<"- ">>, truncate(Text, 400)]);
format_summary(_) ->
    <<>>.

format_cases(Cases) ->
    Lines = [format_case(C) || C <- Cases],
    iolist_to_binary(lists:join(<<"\n">>, Lines)).

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

normalize_history(History) ->
    [normalize_msg(M) || M <- History].

normalize_msg({tool, ToolMsg}) ->
    ToolMsg;
normalize_msg(#{role := _, content := _} = M) ->
    M;
normalize_msg(M) when is_map(M) ->
    M;
normalize_msg(_Other) ->
    #{role => <<"user">>, content => <<>>}.

normalize_tools(Tools) ->
    [normalize_tool(T) || T <- Tools].

normalize_tool(#{name := _} = T) ->
    T#{parameters_json => maps:get(parameters_json, T, <<>>)};
normalize_tool(T) when is_map(T) ->
    T.
