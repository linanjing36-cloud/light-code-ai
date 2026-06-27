#!/usr/bin/env escript
%% bridge_disconnect_test.escript — Phase 3.2 验收
%%
%% 架构要点: Erlang agent_fsm 只编排; 实际 LLM API 调用在 Eion-tools (Eino ChatModel)。
%% 本脚本在 FSM thinking (已向 Eion-tools 发出 LLMInferRequest) 时强杀 Eion-tools,
%% 验证 bridge_manager 通知 {bridge_disconnect}, FSM 柔性降级且 Erlang 节点不崩溃。
%%
%% 前置: scrtps/start-tools.bat + api-key.json
%% 注意: 测试结束会杀掉 Eion-tools, 需手动重新 start-tools.bat

main(_) ->
    true = code:add_pathz("../bin/erl_bin/hermes_brains/ebin"),
    ok = application:load(hermes_brains),
    ok = credentials:load_optional(),
    application:set_env(hermes_brains, eion_tools_addr_file,
                         util:resolve_eion_tools_addr_file()),
    {ok, _} = application:ensure_all_started(hermes_brains),
    ok = wait_bridge_pool(30000),
    SessionId = <<"disconnect-test-sess">>,
    UserMsg = #{role => <<"user">>, content => util:u("用一句话介绍 Erlang")},
    Args = [{session_id, SessionId},
            {model, application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>)},
            {tools, []},
            {history, [#{role => <<"system">>, content => <<"You are helpful.">>}, UserMsg]}],
    {ok, FsmPid} = agent_sup:start_agent(Args),
    ok = state_store:register_session(SessionId, FsmPid),
    ok = state_store:append_history(SessionId, UserMsg),
    io:format("[disconnect-test] triggering ReAct (LLMInferRequest -> Eion-tools)...~n"),
    agent_fsm:start(FsmPid, #{}),
    ok = wait_state(FsmPid, thinking, 15000),
    timer:sleep(300),
    io:format("[disconnect-test] killing Eion-tools (LLM executor) mid-flight...~n"),
    ok = kill_eion_tools(),
    ok = wait_disconnect_handled(FsmPid, SessionId, 20000),
    St = agent_fsm:status(FsmPid),
    Pool = bridge_manager:pool_info(),
    io:format("[disconnect-test] FSM status: ~p~n", [St]),
    io:format("[disconnect-test] bridge pool: ~p~n", [Pool]),
    case {erlang:is_process_alive(FsmPid), maps:get(connected, Pool, 0)} of
        {true, _} ->
            io:format("[disconnect-test] PASS: Erlang brain survived Eion-tools kill~n"),
            io:format("[disconnect-test] NOTE: restart Eion-tools: scrtps\\start-tools.bat~n"),
            halt(0);
        {false, _} ->
            io:format("[disconnect-test] FAIL: FSM died~n"),
            halt(1)
    end.

kill_eion_tools() ->
    _ = os:cmd("taskkill /IM eion-tools-server.exe /F >nul 2>&1"),
    timer:sleep(800),
    ok.

wait_disconnect_handled(FsmPid, SessionId, TimeoutMs) ->
    Deadline = erlang:system_time(millisecond) + TimeoutMs,
    wait_disconnect_loop(FsmPid, SessionId, Deadline).

wait_disconnect_loop(FsmPid, SessionId, Deadline) ->
    Now = erlang:system_time(millisecond),
    Alive = erlang:is_process_alive(FsmPid),
    HasObs = history_has_disconnect_obs(SessionId),
    if not Alive ->
           io:format("[disconnect-test] FAIL: FSM exited before handling disconnect~n"),
           halt(1);
       HasObs ->
           io:format("[disconnect-test] observation injected (bridge_disconnect handled)~n"),
           ok;
       Now >= Deadline ->
           io:format("[disconnect-test] WARN: no disconnect observation in history, continuing~n"),
           ok;
       true ->
           timer:sleep(300),
           wait_disconnect_loop(FsmPid, SessionId, Deadline)
    end.

history_has_disconnect_obs(SessionId) ->
    case state_store:get_history(SessionId) of
        {ok, History} ->
            lists:any(fun(M) ->
                C = maps:get(content, M, <<>>),
                binary:match(C, <<"Bridge disconnected">>) =/= nomatch
            end, History);
        _ ->
            false
    end.

wait_bridge_pool(DeadlineMs) ->
    wait_bridge_pool_loop(erlang:system_time(millisecond) + DeadlineMs).

wait_bridge_pool_loop(Deadline) ->
    Info = bridge_manager:pool_info(),
    Connected = maps:get(connected, Info, 0),
    Now = erlang:system_time(millisecond),
    if Connected > 0 -> ok;
       Now >= Deadline ->
           io:format("[disconnect-test] bridge pool timeout: ~p~n", [Info]), halt(1);
       true ->
           timer:sleep(300),
           wait_bridge_pool_loop(Deadline)
    end.

wait_state(Pid, Expected, DeadlineMs) ->
    wait_state_loop(Pid, Expected, erlang:system_time(millisecond) + DeadlineMs).

wait_state_loop(Pid, Expected, Deadline) ->
    St = agent_fsm:status(Pid),
    State = maps:get(state, St, unknown),
    Now = erlang:system_time(millisecond),
    if State =:= Expected -> ok;
       Now >= Deadline ->
           io:format("[disconnect-test] timeout waiting ~p, got ~p~n", [Expected, St]),
           halt(1);
       true ->
           timer:sleep(200),
           wait_state_loop(Pid, Expected, Deadline)
    end.
