-module(bridge_ping).
%% 小型直连测试: 跳过 FSM, 直接用 bridge_manager 发一次 LLM 请求
%% 验证 Erlang → TCP 连接池 → Eion-tools → LLM → 回链 全链路
%%
%% 前置: 先启动 Eion-tools (scrtps/start-tools.bat), 再执行本模块。
%% Windows: scrtps/run-bridge-ping.bat

-export([run/0]).

-include("log.hrl").

run() ->
    ok = application:load(hermes_brains),
    ok = load_credentials(),
    ok = configure_eion_addr(),
    io:format("[ping] api_key=~s..., model=~s~n",
              [util:safe_prefix(application:get_env(hermes_brains, api_key, <<>>)),
               application:get_env(hermes_brains, default_model, <<>>)]),

    {ok, _} = application:ensure_all_started(hermes_brains),
    io:format("[ping] hermes_brains started~n"),

    ok = wait_pool_ready(erlang:system_time(millisecond) + 30000),
    print_pool_info(),

    Req = #{
        model => application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>),
        messages => [
            #{role => <<"system">>, content => <<"You are a helpful assistant.">>},
            #{role => <<"user">>, content => util:u("用一句话介绍 Erlang")}
        ],
        tools => []
    },

    Ref = bridge_manager:call_llm(self(), Req),
    io:format("[ping] call_llm sent, Ref=~p, waiting up to 90s...~n", [Ref]),

    receive
        {llm_response, Ref, Resp} ->
            io:format("~n[ping] === Got response ===~n"),
            io:format("content: ~s~n", [maps:get(content, Resp, <<>>)]),
            io:format("tool_calls: ~p~n", [maps:get(tool_calls, Resp, [])]),
            io:format("prompt_tokens: ~p~n", [maps:get(prompt_tokens, Resp, 0)]),
            io:format("completion_tokens: ~p~n", [maps:get(completion_tokens, Resp, 0)]),
            Reasoning = maps:get(reasoning_content, Resp, <<>>),
            case Reasoning of
                <<>> -> ok;
                _ -> io:format("reasoning_content (前 200 字): ~s~n",
                               [binary:part(Reasoning, 0, min(byte_size(Reasoning), 200))])
            end,
            io:format("[ping] === end ===~n")
    after 90000 ->
        io:format("[ping] TIMEOUT waiting for response~n"),
        print_pool_info()
    end,

    halt().

configure_eion_addr() ->
    AddrFile = util:resolve_eion_tools_addr_file(),
    application:set_env(hermes_brains, eion_tools_addr_file, AddrFile),
    io:format("[ping] eion_tools_addr_file=~s~n", [AddrFile]),
    ok.

load_credentials() ->
    Path = case os:getenv("API_KEY_FILE") of
        false ->
            case file:read_file("api-key.json") of
                {ok, _} -> "api-key.json";
                _ -> "../api-key.json"
            end;
        P -> P
    end,
    {ok, Body} = file:read_file(Path),
    io:format("[ping] credentials from ~s~n", [Path]),
    Key = maps:get(<<"api_key">>, decode_json(Body), <<>>),
    Model = maps:get(<<"model">>, decode_json(Body), <<"deepseek-v4-pro">>),
    application:set_env(hermes_brains, api_key, Key),
    application:set_env(hermes_brains, default_model, Model),
    ok.

decode_json(Bin) ->
    case code:which(json) of
        non_existing -> util:extract_kv(Bin);
        _ -> json:decode(Bin)
    end.

wait_pool_ready(DeadlineMs) ->
    Info = bridge_manager:pool_info(),
    Connected = maps:get(connected, Info, 0),
    if Connected > 0 ->
           ok;
       true ->
           Now = erlang:system_time(millisecond),
           if Now >= DeadlineMs ->
                  io:format("[ping] pool not ready: ~p~n", [Info]),
                  {error, pool_timeout};
              true ->
                  timer:sleep(500),
                  wait_pool_ready(DeadlineMs)
           end
    end.

print_pool_info() ->
    io:format("[ping] pool_info: ~p~n", [bridge_manager:pool_info()]).
