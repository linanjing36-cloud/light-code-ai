-module(context_assembler_tests).

-include_lib("eunit/include/eunit.hrl").

build_includes_system_and_history_test() ->
    History = [#{role => <<"user">>, content => util:u("北京天气")}],
    Tools = panel_tools:default_tool_descs(),
    Req = context_assembler:build(<<"deepseek-v4-pro">>, #{
        history => History,
        tools => Tools
    }),
    ?assertEqual(<<"deepseek-v4-pro">>, maps:get(model, Req)),
    ?assertEqual(true, maps:get(stream, Req)),
    Msgs = maps:get(messages, Req),
    ?assertEqual(2, length(Msgs)),
    [Sys, User] = Msgs,
    ?assertEqual(<<"system">>, maps:get(role, Sys)),
    ?assertEqual(<<"user">>, maps:get(role, User)),
    ?assertEqual(util:u("北京天气"), maps:get(content, User)),
    ?assertEqual(length(Tools), length(maps:get(tools, Req))).

build_injects_failure_cases_test() ->
    Cases = [#{scenario => util:u("天气查询失败"),
               tool_name => <<"get_weather">>,
               failure_reason => util:u("城市不存在"),
               lesson => util:u("确认城市名")}],
    Req = context_assembler:build(<<"m">>, #{failure_cases => Cases}),
    Sys = hd(maps:get(messages, Req)),
    Content = maps:get(content, Sys),
    ?assert(byte_size(Content) > 100),
    ?assertNotEqual(nomatch, binary:match(Content, util:u("负面案例"))).

build_injects_session_summaries_test() ->
    Summaries = [#{text => util:u("用户喜欢 Erlang"), ts => 1}],
    Req = context_assembler:build(<<"m">>, #{session_summaries => Summaries}),
    Sys = hd(maps:get(messages, Req)),
    Content = maps:get(content, Sys),
    ?assertNotEqual(nomatch, binary:match(Content, util:u("会话摘要"))),
    ?assertNotEqual(nomatch, binary:match(Content, util:u("Erlang"))).

build_injects_memory_snippets_test() ->
    Snippets = [#{content => util:u("用户想学 Elixir"), id => <<"d1">>}],
    Req = context_assembler:build(<<"m">>, #{memory_snippets => Snippets}),
    Sys = hd(maps:get(messages, Req)),
    Content = maps:get(content, Sys),
    ?assertNotEqual(nomatch, binary:match(Content, util:u("相关记忆片段"))),
    ?assertNotEqual(nomatch, binary:match(Content, util:u("Elixir"))).

filter_llm_history_drops_system_test() ->
    Hist = [#{role => <<"system">>, content => <<"old">>},
            #{role => <<"user">>, content => <<"hi">>}],
    ?assertEqual([#{role => <<"user">>, content => <<"hi">>}],
                 context_assembler:filter_llm_history(Hist)).

trim_history_keeps_tail_test() ->
    Hist = [#{role => <<"user">>, content => integer_to_binary(N)} || N <- lists:seq(1, 5)],
    Trimmed = context_assembler:trim_history(Hist, 3),
    ?assertEqual(3, length(Trimmed)),
    ?assertEqual(<<"3">>, maps:get(content, hd(Trimmed))).

build_session_prompt_and_phase_test() ->
    Hist = [#{role => <<"user">>, content => util:u("你好")}],
    Req = context_assembler:build(<<"m">>, #{
        history => Hist,
        session_prompt => util:u("你是天气助手"),
        prompt_phase => first_turn
    }),
    Msgs = maps:get(messages, Req),
    ?assertEqual(2, length(Msgs)),
    Sys = hd(Msgs),
    Content = maps:get(content, Sys),
    ?assertNotEqual(nomatch, binary:match(Content, util:u("会话指令"))),
    ?assertNotEqual(nomatch, binary:match(Content, util:u("天气助手"))),
    ?assertNotEqual(nomatch, binary:match(Content, util:u("首次"))).

build_max_history_msgs_test() ->
    Hist = [#{role => <<"user">>, content => integer_to_binary(N)} || N <- lists:seq(1, 50)],
    Req = context_assembler:build(<<"m">>, #{history => Hist, max_history_msgs => 10}),
    Msgs = maps:get(messages, Req),
    ?assertEqual(11, length(Msgs)),
    ?assertEqual(<<"41">>, maps:get(content, hd(tl(Msgs)))).

