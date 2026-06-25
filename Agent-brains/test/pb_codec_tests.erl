%%====================================================================
%% pb_codec EUnit 测试
%%====================================================================
%%
%% 验证防腐层的 encode_req -> decode_resp / 反向 round-trip 对称性。
%%
%% 注: 源文件中的 binary 字面量 <<"中文">> 在 Erlang epp 下被当作 latin1 字节序列,
%% 即使 erl_opts 设了 {encoding, utf8}, binary 字面量仍然按 latin1 解析。
%% 因此涉及中文的测试数据用 util:u("中文") 帮助函数构造 UTF-8 binary,
%% 这样字符串列表会被按 utf-8 编码读取，再由 unicode:characters_to_binary 转为 UTF-8 binary。
%%====================================================================

-module(pb_codec_tests).

-include_lib("eunit/include/eunit.hrl").
%% 引入项目日志宏 (?log / ?log_warning / ?log_error / ?debug)
%% 在非 debug 模式下 ?debug 编译为 ok, ?log* 走 lager (lager 未启动时为 no-op, 安全)
-include("log.hrl").

%% (u/1 已收拢到 util.erl, 测试中直接用 util:u/1)

%%--------------------------------------------------------------------
%% LLM 请求 round-trip: 业务请求 Map -> binary -> gpb 解码回 Map -> 业务 Map
%%--------------------------------------------------------------------
llm_infer_request_roundtrip_test() ->
    ?log("running ~p", [?FUNCTION_NAME]),
    BizReq = #{kind => llm_infer,
               model => <<"deepseek-v4-pro">>,
               api_base => <<"https://api.deepseek.com">>,
               api_key => <<"sk-test-key">>,
               messages => [#{role => <<"system">>, content => util:u("你是一个助手")},
                            #{role => <<"user">>, content => util:u("北京天气")}],
               tools => [#{name => <<"get_weather">>,
                           description => util:u("获取城市天气"),
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
    %% 验证 UTF-8 中文内容也正确往返
    [ToolDesc] = maps:get(tools, Inner),
    ?assertEqual(util:u("获取城市天气"), maps:get(description, ToolDesc)),
    ?log("~p passed", [?FUNCTION_NAME]),
    ok.

%%--------------------------------------------------------------------
%% ToolExec 请求 round-trip
%%--------------------------------------------------------------------
tool_exec_request_roundtrip_test() ->
    BizReq = #{kind => tool_exec,
               req_id => <<"req-001">>,
               tool_name => <<"get_weather">>,
               arguments_json => util:u("{\"city\":\"北京\"}")},
    Bin = pb_codec:encode_req(BizReq),
    ?assert(is_binary(Bin) andalso byte_size(Bin) > 0),

    DecodedReq = hermes:decode_msg(Bin, 'AgentRequest'),
    ?assertMatch(#{tool_exec := _}, DecodedReq),
    Inner = maps:get(tool_exec, DecodedReq),
    ?assertEqual(<<"req-001">>, maps:get(req_id, Inner)),
    ?assertEqual(<<"get_weather">>, maps:get(tool_name, Inner)),
    ?assertEqual(util:u("{\"city\":\"北京\"}"), maps:get(arguments_json, Inner)),
    ok.

%%--------------------------------------------------------------------
%% LLM 响应解码: 普通 (无 reasoning_content)
%%--------------------------------------------------------------------
llm_infer_response_decode_test() ->
    %% 构造一个 LLMInferResponse binary，模拟从 Go 侧返回的帧负载
    Inner = #{content => util:u("今天北京 25 度"),
              tool_calls => [],
              prompt_tokens => 50,
              completion_tokens => 10},
    AgentResp = #{llm_infer => Inner},
    Bin = hermes:encode_msg(AgentResp, 'AgentResponse'),

    BizResp = pb_codec:decode_resp(Bin),
    ?assertEqual(llm_infer, maps:get(kind, BizResp)),
    ?assertEqual(util:u("今天北京 25 度"), maps:get(content, BizResp)),
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
    Inner = #{content => util:u("最终回答"),
              tool_calls => [],
              prompt_tokens => 100,
              completion_tokens => 80,
              reasoning_content => util:u("正在思考天气查询...")},
    AgentResp = #{llm_infer => Inner},
    Bin = hermes:encode_msg(AgentResp, 'AgentResponse'),

    BizResp = pb_codec:decode_resp(Bin),
    ?assertEqual(util:u("正在思考天气查询..."), maps:get(reasoning_content, BizResp)),
    ?assertEqual(util:u("最终回答"), maps:get(content, BizResp)),
    ok.

%%--------------------------------------------------------------------
%% LLM 响应解码: 带工具调用 (assistant 触发了 tool_call)
%%--------------------------------------------------------------------
llm_infer_response_with_tool_calls_test() ->
    Inner = #{content => <<>>,
              tool_calls => [#{id => <<"call_1">>,
                               name => <<"get_weather">>,
                               arguments => util:u("{\"city\":\"上海\"}")}],
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
    ?assertEqual(util:u("{\"city\":\"上海\"}"), maps:get(arguments, TC)),
    ok.

%%--------------------------------------------------------------------
%% ToolExec 响应解码: 成功
%%--------------------------------------------------------------------
tool_exec_response_success_test() ->
    Inner = #{result_json => util:u("{\"temp\":25,\"city\":\"北京\"}"),
              error => <<>>},
    AgentResp = #{tool_exec => Inner},
    Bin = hermes:encode_msg(AgentResp, 'AgentResponse'),

    BizResp = pb_codec:decode_resp(Bin),
    ?assertEqual(tool_exec, maps:get(kind, BizResp)),
    ?assertEqual(util:u("{\"temp\":25,\"city\":\"北京\"}"), maps:get(result_json, BizResp)),
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
               arguments_json => util:u("{\"city\":\"深圳\"}")},
    ReqBin = pb_codec:encode_req(BizReq),

    %% 2. 解出二进制, 检查请求确实是 tool_exec 分支
    DecodedReq = hermes:decode_msg(ReqBin, 'AgentRequest'),
    ?assertMatch(#{tool_exec := _}, DecodedReq),

    %% 3. 模拟 Go 侧构造响应 (Go 收到 tool_exec 请求 -> 执行 -> 返回 tool_exec 响应)
    GoRespBin = hermes:encode_msg(#{tool_exec => #{result_json => util:u("{\"temp\":30}"),
                                                    error => <<>>}}, 'AgentResponse'),

    %% 4. Erlang 侧解出业务响应
    BizResp = pb_codec:decode_resp(GoRespBin),
    ?assertEqual(tool_exec, maps:get(kind, BizResp)),
    ?assertEqual(util:u("{\"temp\":30}"), maps:get(result_json, BizResp)),
    ok.
