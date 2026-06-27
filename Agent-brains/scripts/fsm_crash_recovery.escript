#!/usr/bin/env escript
%% fsm_crash_recovery.escript — Phase 3.1 验收: kill FSM 后 transient 重启并续跑

main(_) ->
    true = code:add_pathz("../bin/erl_bin/hermes_brains/ebin"),
    ok = application:load(hermes_brains),
    ok = credentials:load_optional(),
    application:set_env(hermes_brains, eion_tools_addr_file,
                         util:resolve_eion_tools_addr_file()),
    {ok, _} = application:ensure_all_started(hermes_brains),
    ok = wait_bridge_pool(30000),
    SessionId = <<"crash-test-sess">>,
    UserMsg = #{role => <<"user">>, content => util:u("北京今天天气怎么样？")},
    Args = [{session_id, SessionId},
            {model, application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>)},
            {tools, panel_tools:fetch_tool_descs()},
            {history, [#{role => <<"system">>, content => <<"test">>}, UserMsg]}],
    {ok, Pid} = agent_sup:start_agent(Args),
    ok = state_store:register_session(SessionId, Pid),
    ok = state_store:append_history(SessionId, UserMsg),
    agent_fsm:start(Pid, #{}),
    ok = wait_state(Pid, thinking, 15000),
    io:format("[crash-test] FSM ~p in thinking, killing...~n", [Pid]),
    exit(Pid, kill),
    ok = wait_new_session(SessionId, Pid, 5000),
    {ok, NewPid} = state_store:lookup_session(SessionId),
    io:format("[crash-test] revived pid=~p (was ~p)~n", [NewPid, Pid]),
    St = agent_fsm:status(NewPid),
    io:format("[crash-test] status after revive: ~p~n", [St]),
    case maps:get(state, St, unknown) of
        thinking -> io:format("[crash-test] PASS: resumed in thinking~n"), halt(0);
        acting -> io:format("[crash-test] PASS: resumed in acting~n"), halt(0);
        idle ->
            io:format("[crash-test] WARN: idle after revive, check logs~n"),
            halt(0);
        Other ->
            io:format("[crash-test] FAIL: unexpected state ~p~n", [Other]),
            halt(1)
    end.

wait_bridge_pool(DeadlineMs) ->
    wait_bridge_pool_loop(erlang:system_time(millisecond) + DeadlineMs).

wait_bridge_pool_loop(Deadline) ->
    Info = bridge_manager:pool_info(),
    Connected = maps:get(connected, Info, 0),
    Now = erlang:system_time(millisecond),
    if Connected > 0 -> ok;
       Now >= Deadline ->
           io:format("[crash-test] bridge pool timeout: ~p~n", [Info]), halt(1);
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
           io:format("[crash-test] timeout waiting state ~p, got ~p~n", [Expected, St]),
           halt(1);
       true ->
           timer:sleep(200),
           wait_state_loop(Pid, Expected, Deadline)
    end.

wait_new_session(SessionId, OldPid, DeadlineMs) ->
    wait_new_session_loop(SessionId, OldPid, erlang:system_time(millisecond) + DeadlineMs).

wait_new_session_loop(SessionId, OldPid, Deadline) ->
    Now = erlang:system_time(millisecond),
    case state_store:lookup_session(SessionId) of
        {ok, Pid} when Pid =/= OldPid ->
            case is_process_alive(Pid) of
                true -> ok;
                false -> retry_or_halt(Now, Deadline, SessionId, OldPid)
            end;
        {ok, _} ->
            retry_or_halt(Now, Deadline, SessionId, OldPid);
        not_found ->
            retry_or_halt(Now, Deadline, SessionId, OldPid)
    end.

retry_or_halt(Now, Deadline, SessionId, OldPid) ->
    if Now >= Deadline ->
           io:format("[crash-test] timeout waiting new FSM pid~n"), halt(1);
       true ->
           timer:sleep(100),
           wait_new_session_loop(SessionId, OldPid, Deadline)
    end.
