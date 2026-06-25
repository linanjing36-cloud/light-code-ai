%%====================================================================
%% pb_codec EUnit 测试
%%====================================================================
%%
%% 验证防腐层的 encode_req -> decode_resp / 反向 round-trip 对称性。
%% 测试用例覆盖:
%%   1. LLMInferRequest  -> AgentRequest 二进制 -> (Go 侧处理) -> AgentResponse 二进制 -> 业务 Map
%%   2. ToolExecRequest  -> AgentRequest 二进制 -> ... -> ToolExecResponse -> 业务 Map
%%   3. v4-pro 推理模型: reasoning_content 字段在响应中能被正确解出
%%   4. 携带 tool_calls 的 assistant 消息往返
%%
%% 这些测试不需要真实 Go 侧，只验证 Erlang 端 Map <-> Protobuf 二进制的对称性。
%%====================================================================

-module(pb_codec_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% LLM 请求 round-trip: 业务请求 Map -> binary -> gpb 解码回 Map -> 业务 Map
%%--------------------------------------------------------------------
llm_infer_request_roundtrip_test() ->
    BizReq = #{kind => llm_infer,
               model => <<"deepseek-v4-pro">>,
               api_base => <<"https://api.deepseek.com">>,
               api_key => <<"sk-test-key">>,
               messages => [#{role => <<"system">>, content => <<"你是一个助手">>},
                            #{role => <<"user">>, content => <<"北京天气">>}],
               tools => [#{name => <<"get_weather">>,
                           description => <<"获取城市天气">>,
                           parameters_json => <<"{\"type\":\"object\"}">>}]},
    Bin = pb_codec:encode_req(BizReq),
    ?assert(is_binary(Bin) andalso byte_size(Bin) > 0),

    %% 模拟 Go 侧把同样的二进制解出来再当作 AgentResponse 处理:
    %% 这里只验证 Erlang 端 encode -> decode 回到 AgentRequest 形态，字段值正确
    DecodedReq = hermes:decode_msg(Bin, 'AgentRequest'),
    ?assertMatch(#{llm_infer := _}, DecodedReq),
    Inner = maps:get(llm_infer, DecodedReq),
    ?assertEqual(<<"deepseek-v4-pro">>, maps:get(model, Inner)),
    ?assertEqual(<<"sk-test-key">>, maps:get(api_key, Inner)),
    ?assertEqual(2, length(maps:get(messages, Inner))),
    ?assertEqual(1, length(maps:get(tools, Inner))),
    ok.

%%--------------------------------------------------------------------
%% ToolExec 请求 round-trip
%%--------------------------------------------------------------------
tool_exec_request_roundtrip_test() ->
    BizReq = #{kind => tool_exec,
               req_id => <<"req-001">>,
               tool_name => <<"get_weather">>,
               arguments_json => <<"{\"city\":\"北京\"}">>},
    Bin = pb_codec:encode_req(BizReq),
    ?assert(is_binary(Bin) andalso byte_size(Bin) > 0),

    DecodedReq = hermes:decode_msg(Bin, 'AgentRequest'),
    ?assertMatch(#{tool_exec := _}, DecodedReq),
    Inner = maps:get(tool_exec, DecodedReq),
    ?assertEqual(<<"req-001">>, maps:get(req_id, Inner)),
    ?assertEqual(<<"get_weather">>, maps:get(tool_name, Inner)),
    ?assertEqual(<<"{\"city\":\"北京\"}">>, maps:get(arguments_json, Inner)),
    ok.

%%--------------------------------------------------------------------
%% LLM 响应解码: 普通 (无 reasoning_content)
%%--------------------------------------------------------------------
llm_infer_response_decode_test() ->
    %% 构造一个 LLMInferResponse binary，模拟从 Go 侧返回的帧负载
    Inner = #{content => <<"今天北京 25 度">>,
              tool_calls => [],
              prompt_tokens => 50,
              completion_tokens => 10},
    AgentResp = #{llm_infer => Inner},
    Bin = hermes:encode_msg(AgentResp, 'AgentResponse'),

    BizResp = pb_codec:decode_resp(Bin),
    ?assertEqual(llm_infer, maps:get(kind, BizResp)),
    ?assertEqual(<<"今天北京 25 度">>, maps:get(content, BizResp)),
    ?assertEqual([], maps:get(tool_calls, BizResp)),
    ?assertEqual(50, maps:get(prompt_tokens, BizResp)),
    ?assertEqual(10, maps:get(completion_tokens, BizResp)),
    %% reasoning_content 缺失时应回退到 <<>>
    ?assertEqual(<<>>, maps:get(reasoning_content, BizResp)),
    ok.

%%--------------------------------------------------------------------
%% LLM 响应解码: v4-pro 推理模型 (含 reasoning_content)
%%--------------------------------------------------------------------
llm_infer_response_with_reasoning_test() ->
    Inner = #{content => <<"最终回答">>,
              tool_calls => [],
              prompt_tokens => 100,
              completion_tokens => 80,
              reasoning_content => <<"正在思考天气查询...">>},
    AgentResp = #{llm_infer => Inner},
    Bin = hermes:encode_msg(AgentResp, 'AgentResponse'),

    BizResp = pb_codec:decode_resp(Bin),
    ?assertEqual(<<"正在思考天气查询...">>, maps:get(reasoning_content, BizResp)),
    ?assertEqual(<<"最终回答">>, maps:get(content, BizResp)),
    ok.

%%--------------------------------------------------------------------
%% LLM 响应解码: 带工具调用 (assistant 触发了 tool_call)
%%--------------------------------------------------------------------
llm_infer_response_with_tool_calls_test() ->
    Inner = #{content => <<>>,
              tool_calls => [#{id => <<"call_1">>,
                               name => <<"get_weather">>,
                               arguments => <<"{\"city\":\"上海\"}">>}],
              prompt_tokens => 30,
              completion_tokens => 20},
    AgentResp = #{llm_infer => Inner},
    Bin = hermes:encode_msg(AgentResp, 'AgentResponse'),

    BizResp = pb_codec:decode_resp(Bin),
    ToolCalls = maps:get(tool_calls, BizResp),
    ?assertEqual(1, length(ToolCalls)),
    [TC] = ToolCalls,
    ?assertEqual(<<"call_1">>, maps:get(id, TC)),
    ?assertEqual(<<"get_weather">>, maps:get(name, TC)),
    ?assertEqual(<<"{\"city\":\"上海\"}">>, maps:get(arguments, TC)),
    ok.

%%--------------------------------------------------------------------
%% ToolExec 响应解码: 成功
%%--------------------------------------------------------------------
tool_exec_response_success_test() ->
    Inner = #{result_json => <<"{\"temp\":25,\"city\":\"北京\"}">>,
              error => <<>>},
    AgentResp = #{tool_exec => Inner},
    Bin = hermes:encode_msg(AgentResp, 'AgentResponse'),

    BizResp = pb_codec:decode_resp(Bin),
    ?assertEqual(tool_exec, maps:get(kind, BizResp)),
    ?assertEqual(<<"{\"temp\":25,\"city\":\"北京\"}">>, maps:get(result_json, BizResp)),
    ?assertEqual(<<>>, maps:get(error, BizResp)),
    ok.

%%--------------------------------------------------------------------
%% ToolExec 响应解码: 失败 (error 非空)
%%--------------------------------------------------------------------
tool_exec_response_failure_test() ->
    Inner = #{result_json => <<>>,
              error => <<"tool not found: unknown_tool">>},
    AgentResp = #{tool_exec => Inner},
    Bin = hermes:encode_msg(AgentResp, 'AgentResponse'),

    BizResp = pb_codec:decode_resp(Bin),
    ?assertEqual(tool_exec, maps:get(kind, BizResp)),
    ?assertEqual(<<"tool not found: unknown_tool">>, maps:get(error, BizResp)),
    ok.

%%--------------------------------------------------------------------
%% 完整端到端 round-trip: 业务请求 -> binary -> 模拟 Go 处理 -> 业务响应
%% 这模拟了真实 Erlang -> Go -> Erlang 的数据流 (Go 侧只做透传验证)
%%--------------------------------------------------------------------
end_to_end_roundtrip_test() ->
    %% 1. Erlang 侧构造业务请求
    BizReq = #{kind => tool_exec,
               req_id => <<"req-e2e">>,
               tool_name => <<"get_weather">>,
               arguments_json => <<"{\"city\":\"深圳\"}">>},
    ReqBin = pb_codec:encode_req(BizReq),

    %% 2. 解出二进制, 检查请求确实是 tool_exec 分支
    DecodedReq = hermes:decode_msg(ReqBin, 'AgentRequest'),
    ?assertMatch(#{tool_exec := _}, DecodedReq),

    %% 3. 模拟 Go 侧构造响应 (Go 收到 tool_exec 请求 -> 执行 -> 返回 tool_exec 响应)
    GoRespBin = hermes:encode_msg(#{tool_exec => #{result_json => <<"{\"temp\":30}">>,
                                                       error => <<>>}}, 'AgentResponse'),

    %% 4. Erlang 侧解出业务响应
    BizResp = pb_codec:decode_resp(GoRespBin),
    ?assertEqual(tool_exec, maps:get(kind, BizResp)),
    ?assertEqual(<<"{\"temp\":30}">>, maps:get(result_json, BizResp)),
    ok.
