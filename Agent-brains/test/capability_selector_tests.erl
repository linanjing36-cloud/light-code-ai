-module(capability_selector_tests).

-include_lib("eunit/include/eunit.hrl").

select_keeps_code_capabilities_for_code_context_test() ->
    Caps = sample_capabilities(),
    Visible = capability_selector:select(Caps, #{
        history => [#{role => <<"user">>, content => util:u("帮我分析这个仓库的代码结构，并搜索相关模块")}]
    }),
    Names = [maps:get(name, Cap) || Cap <- Visible],
    ?assert(lists:member(<<"repo_map">>, Names)),
    ?assert(lists:member(<<"code_search">>, Names)),
    ?assert(lists:member(<<"get_weather">>, Names)).

select_hides_code_capabilities_for_non_code_context_test() ->
    Caps = sample_capabilities(),
    Visible = capability_selector:select(Caps, #{
        history => [#{role => <<"user">>, content => util:u("北京今天天气如何")}]
    }),
    Names = [maps:get(name, Cap) || Cap <- Visible],
    ?assertNot(lists:member(<<"repo_map">>, Names)),
    ?assertNot(lists:member(<<"code_search">>, Names)),
    ?assert(lists:member(<<"get_weather">>, Names)).

select_keeps_memory_capabilities_for_memory_context_test() ->
    Caps = sample_capabilities(),
    Visible = capability_selector:select(Caps, #{
        history => [#{role => <<"user">>, content => util:u("请记住这份文档，并帮我后续检索")}]
    }),
    Names = [maps:get(name, Cap) || Cap <- Visible],
    ?assert(lists:member(<<"memory_store">>, Names)),
    ?assert(lists:member(<<"memory_search">>, Names)),
    ?assert(lists:member(<<"memory_import">>, Names)).

select_blocks_high_risk_capabilities_by_default_test() ->
    Caps = sample_capabilities() ++ [#{
        name => <<"dangerous_exec">>,
        description => <<"dangerous">>,
        parameters_json => <<"{}">>,
        risk_level => <<"high">>,
        tags => [<<"shell">>]
    }],
    Visible = capability_selector:select(Caps, #{
        history => [#{role => <<"user">>, content => util:u("请执行高风险命令")}]
    }),
    Names = [maps:get(name, Cap) || Cap <- Visible],
    ?assertNot(lists:member(<<"dangerous_exec">>, Names)).

normalize_accepts_capability_shape_test() ->
    Cap = capability_selector:normalize(#{
        name => <<"repo_map">>,
        description => <<"repo">>,
        input_schema_json => <<"{\"type\":\"object\"}">>,
        kind => <<"plugin">>,
        source => <<"local">>
    }),
    ?assertEqual(<<"plugin">>, maps:get(kind, Cap)),
    ?assertEqual(<<"local">>, maps:get(source, Cap)),
    ?assertEqual(<<"{\"type\":\"object\"}">>, maps:get(parameters_json, Cap)).

sample_capabilities() ->
    [#{name => <<"get_weather">>,
       description => <<"weather">>,
       parameters_json => <<"{}">>,
       risk_level => <<"safe">>,
       tags => [<<"tool">>]},
     #{name => <<"repo_map">>,
       description => <<"repo">>,
       parameters_json => <<"{}">>,
       kind => <<"plugin">>,
       source => <<"local">>,
       risk_level => <<"safe">>,
       tags => [<<"plugin">>, <<"workspace">>, <<"token-saving">>]},
     #{name => <<"code_search">>,
       description => <<"code">>,
       parameters_json => <<"{}">>,
       kind => <<"plugin">>,
       source => <<"local">>,
       risk_level => <<"safe">>,
       tags => [<<"plugin">>, <<"code">>, <<"search">>]},
     #{name => <<"memory_store">>,
       description => <<"memory store">>,
       parameters_json => <<"{}">>,
       risk_level => <<"safe">>,
       tags => [<<"tool">>, <<"memory">>]},
     #{name => <<"memory_search">>,
       description => <<"memory search">>,
       parameters_json => <<"{}">>,
       risk_level => <<"safe">>,
       tags => [<<"tool">>, <<"memory">>, <<"search">>]},
     #{name => <<"memory_import">>,
       description => <<"memory import">>,
       parameters_json => <<"{}">>,
       risk_level => <<"safe">>,
       tags => [<<"tool">>, <<"memory">>, <<"import">>]}].
