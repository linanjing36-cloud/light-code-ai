-module(approval_store_tests).

-include_lib("eunit/include/eunit.hrl").

%% 测试夹具: 每个测试启动独立的 approval_store gen_server
setup() ->
    {ok, Pid} = approval_store:start_link(),
    Pid.

cleanup(Pid) ->
    try gen_server:stop(Pid) catch _:_ -> ok end.

approval_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun register_and_lookup/1,
      fun register_duplicate_pending/1,
      fun resolve_approve/1,
      fun resolve_reject/1,
      fun resolve_not_found/1,
      fun resolve_already_resolved/1,
      fun cancel_pending/1,
      fun cancel_idempotent/1,
      fun list_pending_only/1,
      fun list_by_session/1,
      fun delete_entry/1,
      fun register_overwrites_resolved/1]}.

%% register + lookup pending
register_and_lookup(_Pid) ->
    ReqId = <<"req-1">>,
    Me = self(),
    ok = approval_store:register(ReqId, Me, <<"sess-1">>, #{tool => <<"rm">>}),
    {ok, Entry} = approval_store:lookup(ReqId),
    [
     ?_assertEqual(ReqId, maps:get(req_id, Entry)),
     ?_assertEqual(Me, maps:get(fsm_pid, Entry)),
     ?_assertEqual(<<"sess-1">>, maps:get(session_id, Entry)),
     ?_assertEqual(pending, maps:get(status, Entry)),
     ?_assertEqual(#{tool => <<"rm">>}, maps:get(tool_call, Entry))
    ].

%% register 重复 pending req_id 失败
register_duplicate_pending(_Pid) ->
    ReqId = <<"req-2">>,
    ok = approval_store:register(ReqId, self(), <<"sess-2">>, #{}),
    ?_assertEqual({error, already_exists}, approval_store:register(ReqId, self(), <<"sess-2">>, #{})).

%% resolve allow=true -> approved
resolve_approve(_Pid) ->
    ReqId = <<"req-3">>,
    ok = approval_store:register(ReqId, self(), <<"sess-3">>, #{tool => <<"exec">>}),
    {ok, Entry} = approval_store:resolve(ReqId, true),
    [
     ?_assertEqual(approved, maps:get(status, Entry)),
     ?_assertEqual(ReqId, maps:get(req_id, Entry))
    ].

%% resolve allow=false -> rejected
resolve_reject(_Pid) ->
    ReqId = <<"req-4">>,
    ok = approval_store:register(ReqId, self(), <<"sess-4">>, #{}),
    {ok, Entry} = approval_store:resolve(ReqId, false),
    ?_assertEqual(rejected, maps:get(status, Entry)).

%% resolve 不存在 -> not_found
resolve_not_found(_Pid) ->
    ?_assertEqual(not_found, approval_store:resolve(<<"nonexistent">>, true)).

%% resolve 已 resolved -> {error, not_pending}
resolve_already_resolved(_Pid) ->
    ReqId = <<"req-5">>,
    ok = approval_store:register(ReqId, self(), <<"sess-5">>, #{}),
    {ok, _} = approval_store:resolve(ReqId, true),
    ?_assertEqual({error, not_pending}, approval_store:resolve(ReqId, true)).

%% cancel pending -> ok, status 变 canceled
cancel_pending(_Pid) ->
    ReqId = <<"req-6">>,
    ok = approval_store:register(ReqId, self(), <<"sess-6">>, #{}),
    ok = approval_store:cancel(ReqId),
    {ok, Entry} = approval_store:lookup(ReqId),
    ?_assertEqual(canceled, maps:get(status, Entry)).

%% cancel 不存在 -> ok (幂等)
cancel_idempotent(_Pid) ->
    ?_assertEqual(ok, approval_store:cancel(<<"nonexistent">>)).

%% list_pending 只返回 pending 状态
list_pending_only(_Pid) ->
    ok = approval_store:register(<<"p1">>, self(), <<"s">>, #{}),
    ok = approval_store:register(<<"p2">>, self(), <<"s">>, #{}),
    {ok, _} = approval_store:resolve(<<"p2">>, true),
    Pending = approval_store:list_pending(),
    PendingIds = [maps:get(req_id, E) || E <- Pending],
    [
     ?_assert(lists:member(<<"p1">>, PendingIds)),
     ?_assertNot(lists:member(<<"p2">>, PendingIds))
    ].

%% list_by_session 按会话过滤
list_by_session(_Pid) ->
    ok = approval_store:register(<<"s1-a">>, self(), <<"sess-a">>, #{}),
    ok = approval_store:register(<<"s1-b">>, self(), <<"sess-a">>, #{}),
    ok = approval_store:register(<<"s2-a">>, self(), <<"sess-b">>, #{}),
    Entries = approval_store:list_by_session(<<"sess-a">>),
    Ids = [maps:get(req_id, E) || E <- Entries],
    [
     ?_assertEqual(2, length(Ids)),
     ?_assert(lists:member(<<"s1-a">>, Ids)),
     ?_assert(lists:member(<<"s1-b">>, Ids))
    ].

%% delete -> ok, lookup not_found
delete_entry(_Pid) ->
    ReqId = <<"req-7">>,
    ok = approval_store:register(ReqId, self(), <<"sess-7">>, #{}),
    ok = approval_store:delete(ReqId),
    ?_assertEqual(not_found, approval_store:lookup(ReqId)).

%% register 覆盖已 resolved 条目 (新轮次注册)
register_overwrites_resolved(_Pid) ->
    ReqId = <<"req-8">>,
    ok = approval_store:register(ReqId, self(), <<"sess-8">>, #{round => 1}),
    {ok, _} = approval_store:resolve(ReqId, true),
    %% 新轮次用同 ReqId 注册 (业务上 Erlang 会生成新 ReqId, 这里测覆盖能力)
    ok = approval_store:register(ReqId, self(), <<"sess-8">>, #{round => 2}),
    {ok, Entry} = approval_store:lookup(ReqId),
    [
     ?_assertEqual(pending, maps:get(status, Entry)),
     ?_assertEqual(2, maps:get(round, maps:get(tool_call, Entry)))
    ].
