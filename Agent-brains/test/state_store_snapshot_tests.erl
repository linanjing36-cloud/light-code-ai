-module(state_store_snapshot_tests).

-include_lib("eunit/include/eunit.hrl").

snapshot_tuple_roundtrip_test() ->
    {ok, _} = application:ensure_all_started(hermes_brains),
    Sess = <<"snap-test-1">>,
    Data = #{
        session_id => Sess,
        loop_count => 2,
        placeholder => true
    },
    %% agent_fsm #data{} 在测试里用 map 模拟存储格式
    Snap = {thinking, Data},
    ok = state_store:put_snapshot(Sess, Snap),
    ?assertEqual({ok, Snap}, state_store:get_snapshot(Sess)),
    ok = state_store:put_snapshot(Sess, {acting, Data}),
    ?assertEqual({ok, {acting, Data}}, state_store:get_snapshot(Sess)).

legacy_data_snapshot_test() ->
    {ok, _} = application:ensure_all_started(hermes_brains),
    Sess = <<"snap-test-legacy">>,
    Legacy = #{session_id => Sess, v => 1},
    ok = state_store:put_snapshot(Sess, Legacy),
    ?assertEqual({ok, Legacy}, state_store:get_snapshot(Sess)).
