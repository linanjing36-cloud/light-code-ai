-module(agent_memory_demo).

%% Step 4.1a 联调: ReAct + memory_store / memory_search (Redis Stack + Eino)
-export([run/0, run/1]).

-define(SESSION, <<"memory-demo-sess">>).

run() ->
    Query = util:u(
        "当前 session_id 是 memory-demo-sess。"
        "请先用 memory_store 记住：我最喜欢的编程语言是 Erlang。"
        "然后用 memory_search 搜索「编程语言」并告诉我你找到了什么。"),
    run(Query).

run(Query) when is_binary(Query) ->
    ok = application:load(hermes_brains),
    ok = agent_demo:load_credentials(),
    ok = agent_demo:configure_eion_addr(),
    ok = agent_demo:ensure_started(),
    agent_demo:print_env(),
    ok = agent_demo:wait_bridge_pool(30000),
    {ok, FsmPid} = start_fsm(Query),
    io:format("~n=== memory demo FSM PID=~p ===~n", [FsmPid]),
    agent_fsm:start(FsmPid, #{}),
    ok = agent_demo:wait_idle(FsmPid, ?SESSION, 120000),
    agent_demo:print_history(?SESSION),
    ok.

start_fsm(Query) ->
    Tools = panel_tools:fetch_tool_descs(),
    InitialHistory = [#{role => <<"user">>, content => Query}],
    Args = [{session_id, ?SESSION},
            {model, application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>)},
            {tools, Tools},
            {history, InitialHistory}],
    case agent_sup:start_agent(Args) of
        {ok, Pid} ->
            [state_store:append_history(?SESSION, M) || M <- InitialHistory],
            {ok, Pid};
        {error, _} = E ->
            E
    end.
