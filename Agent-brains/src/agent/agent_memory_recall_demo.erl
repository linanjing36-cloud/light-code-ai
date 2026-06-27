-module(agent_memory_recall_demo).

%% Step 4.1 验收: 多轮记忆召回 (向量 RAG 预取 + 可选 ReAct)
-export([run/0, seed_memory/1]).

-define(SESSION, <<"memory-recall-demo">>).

run() ->
    ok = application:load(hermes_brains),
    ok = agent_demo:load_credentials(),
    ok = agent_demo:configure_eion_addr(),
    ok = agent_demo:ensure_started(),
    agent_demo:print_env(),
    ok = agent_demo:wait_bridge_pool(30000),
    ok = seed_memory(?SESSION),
    Query = util:u("我第一轮说了什么？请根据长期记忆简要回答。"),
    {ok, FsmPid} = start_fsm(Query),
    io:format("~n=== memory recall demo FSM PID=~p ===~n", [FsmPid]),
    agent_fsm:start(FsmPid, #{}),
    ok = agent_demo:wait_idle(FsmPid, ?SESSION, 120000),
    agent_demo:print_history(?SESSION),
    ok.

%% 预置向量记忆 (不经 LLM, 直接 memory_store)
seed_memory(SessionId) ->
    Text = util:u("用户第一轮表示：我想学习 Elixir 编程语言，用于构建分布式系统。"),
    Args = json:encode(#{<<"session_id">> => SessionId, <<"text">> => Text}),
    Id = iolist_to_binary(["seed-", integer_to_binary(erlang:unique_integer([positive]))]),
    case bridge_manager:call_tool_sync(
           #{id => Id, name => <<"memory_store">>, arguments => Args}, 15000) of
        {ok, Resp} ->
            io:format("[recall-demo] seeded memory: ~p~n", [maps:get(result_json, Resp, <<>>)]),
            ok;
        {error, Reason} ->
            io:format("[recall-demo] seed failed: ~p~n", [Reason]),
            {error, Reason}
    end.

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
