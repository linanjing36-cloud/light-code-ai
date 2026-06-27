-module(panel_pb_codec_tests).

-include_lib("eunit/include/eunit.hrl").

start_session_roundtrip_test() ->
    Args = #{system_prompt => <<"你是 Hermes">>},
    Bin = panel_pb_codec:pack_request(1, <<"start_session">>, Args),
    ?assert(is_binary(Bin)),
    {request, 1, <<"start_session">>, DecArgs} = panel_pb_codec:unpack_frame(Bin),
    ?assertEqual(Args, DecArgs),
    Result = #{session_id => <<"sess-123">>},
    RespBin = panel_pb_codec:pack_response_ok(1, <<"start_session">>, Result),
    {response, 1, ok, ResultBytes} = panel_pb_codec:unpack_frame(RespBin),
    ?assertEqual(Result, panel_pb_codec:decode_result(<<"start_session">>, ResultBytes)).

brain_status_roundtrip_test() ->
    Args = #{session_id => <<"sess-1">>},
    ReqBin = panel_pb_codec:pack_request(2, <<"brain_status">>, Args),
    {request, 2, <<"brain_status">>, DecArgs} = panel_pb_codec:unpack_frame(ReqBin),
    ?assertEqual(Args, DecArgs),
    Status = #{state => idle, loop_count => 1, max_loops => 10, history_len => 3},
    RespBin = panel_pb_codec:pack_response_ok(2, <<"brain_status">>, Status),
    {response, 2, ok, ResultBytes} = panel_pb_codec:unpack_frame(RespBin),
    Dec = panel_pb_codec:decode_result(<<"brain_status">>, ResultBytes),
    ?assertEqual(<<"idle">>, maps:get(state, Dec)),
    ?assertEqual(1, maps:get(loop_count, Dec)),
    ?assertEqual(10, maps:get(max_loops, Dec)),
    ?assertEqual(3, maps:get(history_len, Dec)).

send_roundtrip_test() ->
    Args = #{session_id => <<"sess-1">>, message => <<"hello">>},
    Bin = panel_pb_codec:pack_request(3, <<"send">>, Args),
    {request, 3, <<"send">>, DecArgs} = panel_pb_codec:unpack_frame(Bin),
    ?assertEqual(Args, DecArgs).

response_error_test() ->
    ErrBin = panel_pb_codec:pack_response_err(9, <<"bad_method">>),
    {response, 9, error, <<"bad_method">>} = panel_pb_codec:unpack_frame(ErrBin).

get_history_roundtrip_test() ->
    Args = #{session_id => <<"sess-1">>},
    Bin = panel_pb_codec:pack_request(4, <<"get_history">>, Args),
    {request, 4, <<"get_history">>, DecArgs} = panel_pb_codec:unpack_frame(Bin),
    ?assertEqual(Args, DecArgs),
    Msgs = [
        #{role => <<"user">>, content => <<"hello">>},
        #{role => <<"assistant">>, content => <<>>, tool_calls => [
            #{id => <<"tc1">>, name => <<"get_weather">>, arguments => <<"{\"city\":\"beijing\"}">>}
        ]}
    ],
    RespBin = panel_pb_codec:pack_response_ok(4, <<"get_history">>, #{messages => Msgs}),
    {response, 4, ok, ResultBytes} = panel_pb_codec:unpack_frame(RespBin),
    Dec = panel_pb_codec:decode_result(<<"get_history">>, ResultBytes),
    DecMsgs = maps:get(messages, Dec),
    ?assertEqual(2, length(DecMsgs)),
    [_, Asst] = DecMsgs,
    ?assertEqual(1, length(maps:get(tool_calls, Asst))).
