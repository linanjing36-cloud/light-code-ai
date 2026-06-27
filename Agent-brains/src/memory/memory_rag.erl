-module(memory_rag).

%% Step 4.1c: thinking 前经 Eion-tools memory_search 预取 RAG 片段
-export([prefetch/2]).

-define(TOP_K, 3).
-define(SYNC_TIMEOUT, 10000).

-spec prefetch(binary(), [map()]) -> [map()].
prefetch(SessionId, History) when is_binary(SessionId), is_list(History) ->
    case last_user_query(History) of
        {ok, Query} ->
            do_search(SessionId, Query);
        _ ->
            []
    end.

do_search(SessionId, Query) ->
    Args = encode_args(SessionId, Query),
    Id = iolist_to_binary(["rag-", integer_to_binary(erlang:unique_integer([positive]))]),
    ToolCall = #{id => Id,
                 name => <<"memory_search">>,
                 arguments => Args},
    try bridge_manager:call_tool_sync(ToolCall, ?SYNC_TIMEOUT) of
        {ok, Resp} ->
            parse_hits(Resp);
        {error, _} ->
            []
    catch _:_ ->
        []
    end.

last_user_query(History) ->
    UserMsgs = [maps:get(content, M, <<>>)
                || M <- History,
                   maps:get(role, M, <<>>) =:= <<"user">>,
                   maps:get(content, M, <<>>) =/= <<>>],
    case lists:reverse(UserMsgs) of
        [Q | _] -> {ok, Q};
        [] -> error
    end.

encode_args(SessionId, Query) ->
    Payload = #{<<"query">> => Query,
                <<"session_id">> => SessionId,
                <<"top_k">> => ?TOP_K},
    json:encode(Payload).

parse_hits(#{result_json := Json}) when is_binary(Json), Json =/= <<>> ->
    case decode_json(Json) of
        #{<<"hits">> := Hits} when is_list(Hits) ->
            [normalize_hit(H) || H <- Hits, is_map(H)];
        _ ->
            []
    end;
parse_hits(#{error := Err}) when is_binary(Err), Err =/= <<>> ->
    [];
parse_hits(_) ->
    [].

normalize_hit(H) ->
    Content = maps:get(<<"content">>, H, maps:get(content, H, <<>>)),
    Id = maps:get(<<"id">>, H, maps:get(id, H, <<>>)),
    #{content => Content, id => Id}.

decode_json(Bin) ->
    case code:which(json) of
        non_existing -> #{};
        _ -> json:decode(Bin)
    end.
