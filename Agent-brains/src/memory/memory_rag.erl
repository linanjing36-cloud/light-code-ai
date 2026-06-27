-module(memory_rag).

%% Step 4.1c: thinking 前经 Eion-tools memory_search 预取 RAG 片段
%% EXEC-P1-013: 新增 agentmemory 优先召回 (search MCP 工具), prefetch/2 作为本地降级
-export([prefetch/2, search_agentmemory/2]).

-define(TOP_K, 3).
-define(AM_TOP_K, 5).
-define(SYNC_TIMEOUT, 10000).

-spec prefetch(binary(), [map()]) -> [map()].
prefetch(SessionId, History) when is_binary(SessionId), is_list(History) ->
    case last_user_query(History) of
        {ok, Query} ->
            do_search(SessionId, Query);
        _ ->
            []
    end.

%%====================================================================
%% agentmemory 优先召回 (EXEC-P1-013)
%% 经 Eion-tools MCP client manager 调用 agentmemory 的 search 工具。
%% 走现有 bridge → panel exec → Eion-tools → MCP 链路, 不引入新通道。
%% 返回 [] 表示 agentmemory 不可用/无结果, 由 context_assembler 决定是否降级。
%%====================================================================
-spec search_agentmemory(binary(), [map()]) -> [map()].
search_agentmemory(SessionId, History) when is_binary(SessionId), is_list(History) ->
    case last_user_query(History) of
        {ok, Query} ->
            do_agentmemory_search(SessionId, Query);
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

do_agentmemory_search(SessionId, Query) ->
    Args = encode_agentmemory_args(SessionId, Query),
    Id = iolist_to_binary(["am-search-", integer_to_binary(erlang:unique_integer([positive]))]),
    ToolCall = #{id => Id,
                 name => <<"search">>,
                 arguments => Args},
    try bridge_manager:call_tool_sync(ToolCall, ?SYNC_TIMEOUT) of
        {ok, Resp} ->
            parse_agentmemory_hits(Resp);
        {error, Reason} ->
            lager:warning("agentmemory search failed: tool=search reason=~p", [Reason]),
            []
    catch Class:Reason:Stack ->
        lager:warning("agentmemory search exception: tool=search ~p:~p stack=~p",
                      [Class, Reason, Stack]),
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

encode_agentmemory_args(SessionId, Query) ->
    Payload = #{<<"query">> => Query,
                <<"session_id">> => SessionId,
                <<"top_k">> => ?AM_TOP_K},
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

%% agentmemory search 响应格式兼容: hits / results / 裸数组
parse_agentmemory_hits(#{result_json := Json}) when is_binary(Json), Json =/= <<>> ->
    case decode_json(Json) of
        #{<<"hits">> := Hits} when is_list(Hits) ->
            [normalize_hit(H) || H <- Hits, is_map(H)];
        #{<<"results">> := Hits} when is_list(Hits) ->
            [normalize_hit(H) || H <- Hits, is_map(H)];
        Hits when is_list(Hits) ->
            [normalize_hit(H) || H <- Hits, is_map(H)];
        _ ->
            []
    end;
parse_agentmemory_hits(#{error := Err}) when is_binary(Err), Err =/= <<>> ->
    [];
parse_agentmemory_hits(_) ->
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
