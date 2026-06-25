-module(bridge_ping).
%% 小型直连测试: 跳过 FSM, 直接用 bridge_manager 发一次 LLM 请求
%% 验证 Erlang→Port→Go→DeepSeek→回链 全链路

-export([run/0]).

-include_lib("kernel/include/logger.hrl").

run() ->
    %% 1. 准备 env
    ok = application:load(hermes_brains),
    {ok, Body} = file:read_file("../api-key.json"),
    ApiKey = maps:get(<<"api_key">>, json:decode(Body), <<>>),
    Model = maps:get(<<"model">>, json:decode(Body), <<"deepseek-v4-pro">>),
    application:set_env(hermes_brains, api_key, ApiKey),
    application:set_env(hermes_brains, default_model, Model),
    application:set_env(hermes_brains, eion_tools_bin, "/tmp/eion-tools-server"),
    io:format("[ping] api_key=~s..., model=~s~n", [safe_prefix(ApiKey), Model]),

    %% 2. 启动 app
    {ok, _} = application:ensure_all_started(hermes_brains),
    io:format("[ping] hermes_brains started~n"),

    %% 3. 构造一个最简 LLM 请求
    Req = #{
        model => Model,
        messages => [
            #{role => <<"system">>, content => <<"You are a helpful assistant.">>},
            #{role => <<"user">>, content => u("用一句话介绍 Erlang")}
        ],
        tools => []
    },

    %% 4. 用 self() 作为 FSM, 调用 call_llm
    Ref = bridge_manager:call_llm(self(), Req),
    io:format("[ping] call_llm sent, Ref=~p, waiting up to 90s...~n", [Ref]),

    %% 5. 等响应
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
        %% 调试: 查看队列与 port 状态
        PortInfo = bridge_manager:port_info(),
        QueueLen = bridge_manager:queue_len(),
        io:format("[ping] port=~p, queue_len=~p~n", [PortInfo, QueueLen])
    end,

    halt().

safe_prefix(Key) when byte_size(Key) >= 8 ->
    <<Pre:8/binary, _/binary>> = Key,
    Pre;
safe_prefix(_) -> "****".

u(Str) -> unicode:characters_to_binary(Str, utf8).
