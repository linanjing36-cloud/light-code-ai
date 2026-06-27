-module(session_prompt_integration_tests).

-include_lib("eunit/include/eunit.hrl").

start_session_history_has_no_system_test() ->
    {ok, _} = application:ensure_all_started(hermes_brains),
    SessionId = unique_session_id(),
    CustomPrompt = util:u("你是专用测试助手，只回答天气问题"),
    FSMArgs = [{session_id, SessionId},
               {model, <<"test-model">>},
               {tools, []},
               {session_prompt, CustomPrompt},
               {history, []}],
    {ok, Pid} = agent_sup:start_agent(FSMArgs),
    ok = state_store:register_session(SessionId, Pid),
    {ok, History} = state_store:get_history(SessionId),
    ?assertEqual([], History),
    HasSystem = lists:any(
        fun(M) -> maps:get(role, M, <<>>) =:= <<"system">> end,
        History
    ),
    ?assertEqual(false, HasSystem),
    _ = gen_statem:stop(Pid, normal, infinity).

context_assembler_injects_session_prompt_test() ->
    {ok, _} = application:ensure_all_started(hermes_brains),
    SessionId = unique_session_id(),
    CustomPrompt = util:u("你是专用测试助手"),
    FSMArgs = [{session_id, SessionId},
               {model, <<"test-model">>},
               {tools, []},
               {session_prompt, CustomPrompt},
               {history, []}],
    {ok, Pid} = agent_sup:start_agent(FSMArgs),
    ok = state_store:register_session(SessionId, Pid),
    UserMsg = #{role => <<"user">>, content => util:u("北京天气如何？")},
    ok = state_store:append_history(SessionId, UserMsg),
    {ok, History} = state_store:get_history(SessionId),
    ?assertEqual(1, length(History)),
    ?assertEqual(<<"user">>, maps:get(role, hd(History))),
    Req = context_assembler:build(<<"test-model">>, #{
        history => History,
        tools => [],
        session_prompt => CustomPrompt,
        prompt_phase => first_turn
    }),
    Msgs = maps:get(messages, Req),
    ?assertEqual(2, length(Msgs)),
    [Sys, User] = Msgs,
    ?assertEqual(<<"system">>, maps:get(role, Sys)),
    SysContent = maps:get(content, Sys),
    ?assertNotEqual(nomatch, binary:match(SysContent, util:u("会话指令"))),
    ?assertNotEqual(nomatch, binary:match(SysContent, CustomPrompt)),
    ?assertNotEqual(nomatch, binary:match(SysContent, util:u("首次"))),
    ?assertEqual(util:u("北京天气如何？"), maps:get(content, User)),
    _ = gen_statem:stop(Pid, normal, infinity).

unique_session_id() ->
    Ts = integer_to_binary(erlang:system_time(millisecond)),
    <<"sess-prompt-", Ts/binary>>.
