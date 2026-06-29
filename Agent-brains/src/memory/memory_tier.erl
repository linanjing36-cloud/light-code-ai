-module(memory_tier).
-behaviour(gen_server).

%%====================================================================
%% Memory_Tier —— 分层长期记忆 (facts / preferences / workspace)
%%====================================================================
%%
%% 三层记忆模型 (EXEC-P2-002):
%%   facts       —— 用户陈述的事实 (如"我用 Erlang","项目名是 Hermes")
%%   preferences —— 用户偏好 (如"回答简洁","中文注释","测试先行")
%%   workspace   —— 工作区上下文 (如"这是 Go+Erlang 项目","前端用 Wails")
%%
%% 存储: Mnesia disc_copies 表 `tiered_memories`, 按 session_id + tier 索引。
%% 每条记忆: #{tier, key, content, session_id, ts, source}
%%   - key 为去重键 (内容的归一化哈希), 相同 key 写入更新 content
%%   - session_id = <<"global">> 表示跨会话全局记忆 (用户级偏好)
%%
%% 写入入口:
%%   - put/4,put/5       手动写入 (经 memory_fact/memory_preference/memory_workspace 工具)
%%   - schedule_extract/2 从对话历史中异步 LLM 抽取并写入 (final answer 后触发)
%%
%% 读取入口:
%%   - get_tier/2    获取某会话某层的全部记忆 (自动合并 global 层)
%%   - get_all/1     获取某会话的全部三层记忆 (供 context_assembler 注入)
%%
%% 生命周期:
%%   - purge_session/1  删除会话时清理该会话的非全局记忆
%%   - start_link/0     由顶层 supervisor 启动 (在 mnesia_store 之后)
%%====================================================================

-export([start_link/0,
         put/4, put/5,
         get_tier/2, get_all/1,
         delete/3,
         purge_session/1,
         schedule_extract/2,
         store_extracted/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("log.hrl").

-define(SERVER, ?MODULE).
-define(TABLE, tiered_memories).
-define(LLM_TIMEOUT, 20000).
-define(EXTRACT_HISTORY_LIMIT, 20).

-record(state, {
    pending = #{} :: #{reference() => {binary(), reference()}}
}).

-type tier() :: facts | preferences | workspace.
-export_type([tier/0]).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% 写入一条分层记忆 (key 自动从 content 生成)
-spec put(binary(), tier(), binary(), binary()) -> ok | {error, term()}.
put(SessionId, Tier, Content, Source) when is_binary(SessionId), is_binary(Content) ->
    Key = make_key(Content),
    put(SessionId, Tier, Key, Content, Source).

%% 写入一条分层记忆 (指定 key 用于幂等更新)
-spec put(binary(), tier(), binary(), binary(), binary()) -> ok | {error, term()}.
put(SessionId, Tier, Key, Content, Source)
  when is_binary(SessionId), is_binary(Key), is_binary(Content) ->
    gen_server:call(?SERVER, {put, SessionId, Tier, Key, Content, Source}, 5000).

%% 获取某会话某层的记忆列表 (按 ts 倒序, 自动合并 global 层)
-spec get_tier(binary(), tier()) -> [map()].
get_tier(SessionId, Tier) when is_binary(SessionId) ->
    S = get_tier_internal(SessionId, Tier),
    G = case SessionId of
            <<"global">> -> [];
            _ -> get_tier_internal(<<"global">>, Tier)
        end,
    merge_by_key(G ++ S).

%% 获取某会话的全部三层记忆
-spec get_all(binary()) -> #{tier() => [map()]}.
get_all(SessionId) when is_binary(SessionId) ->
    #{facts => get_tier(SessionId, facts),
      preferences => get_tier(SessionId, preferences),
      workspace => get_tier(SessionId, workspace)}.

%% 删除一条记忆
-spec delete(binary(), tier(), binary()) -> ok | {error, term()}.
delete(SessionId, Tier, Key) when is_binary(SessionId), is_binary(Key) ->
    gen_server:call(?SERVER, {delete, SessionId, Tier, Key}, 5000).

%% 删除会话时清理该会话的全部非全局记忆
-spec purge_session(binary()) -> ok.
purge_session(SessionId) when is_binary(SessionId) ->
    gen_server:cast(?SERVER, {purge_session, SessionId}).

%% 异步触发: 从对话历史中 LLM 抽取三层记忆并写入
-spec schedule_extract(binary(), [map()]) -> ok.
schedule_extract(SessionId, History) ->
    gen_server:cast(?SERVER, {extract, SessionId, History}),
    ok.

%% 直接存储已抽取好的记忆 (Memories = #{facts => [...], preferences => [...], workspace => [...]})
-spec store_extracted(binary(), map()) -> ok.
store_extracted(SessionId, Memories) ->
    gen_server:call(?SERVER, {store_extracted, SessionId, Memories}, 5000).

%%====================================================================
%% gen_server 回调
%%====================================================================

init([]) ->
    case create_table() of
        ok ->
            ?log("memory_tier started, table=~p", [?TABLE]),
            {ok, #state{}};
        {error, Reason} = Err ->
            ?log_error("memory_tier init failed: ~p", [Reason]),
            {stop, Err}
    end.

handle_call({put, SessionId, Tier, Key, Content, Source}, _From, State) ->
    Result = do_put(SessionId, Tier, Key, Content, Source),
    {reply, Result, State};

handle_call({delete, SessionId, Tier, Key}, _From, State) ->
    Result = do_delete(SessionId, Tier, Key),
    {reply, Result, State};

handle_call({store_extracted, SessionId, Memories}, _From, State) ->
    do_store_extracted(SessionId, Memories),
    {reply, ok, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({extract, SessionId, History}, State) ->
    case has_pending_session(State, SessionId) of
        true ->
            {noreply, State};
        false ->
            case build_extract_request(History) of
                {ok, Req} ->
                    Ref = bridge_manager:call_llm(self(), Req),
                    TRef = erlang:send_after(?LLM_TIMEOUT, self(), {extract_timeout, Ref}),
                    Pending1 = maps:put(Ref, {SessionId, TRef}, State#state.pending),
                    {noreply, State#state{pending = Pending1}};
                skip ->
                    {noreply, State}
            end
    end;

handle_cast({llm_response, Ref, Response}, State) ->
    {noreply, handle_llm_response(Ref, Response, State)};

handle_cast({purge_session, SessionId}, State) ->
    do_purge_session(SessionId),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({extract_timeout, Ref}, State) ->
    case maps:get(Ref, State#state.pending, undefined) of
        undefined ->
            {noreply, State};
        {SessionId, _TRef} ->
            ?log_warning("memory_tier extract timeout session=~s ref=~p", [SessionId, Ref]),
            Pending1 = maps:remove(Ref, State#state.pending),
            {noreply, State#state{pending = Pending1}}
    end;

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% 内部: Mnesia 存储
%%====================================================================

create_table() ->
    Node = node(),
    case mnesia:create_table(?TABLE, [
        {attributes, [mem_id, session_id, tier, key, content, ts, source]},
        {disc_copies, [Node]},
        {type, set}
    ]) of
        {atomic, ok} ->
            ok = ensure_indexes(),
            ?log("tiered_memories table created (disc_copies)"),
            ok;
        {aborted, {already_exists, _}} ->
            _ = ensure_indexes(),
            ok;
        {aborted, Reason} ->
            {error, {create_table_failed, Reason}}
    end.

ensure_indexes() ->
    case mnesia:add_table_index(?TABLE, session_id) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, _, _}} -> ok;
        _ -> ok
    end.

do_put(SessionId, Tier, Key, Content, Source) ->
    Ts = erlang:system_time(millisecond),
    MemId = make_mem_id(SessionId, Tier, Key),
    Rec = {?TABLE, MemId, SessionId, Tier, Key, Content, Ts, Source},
    case mnesia:transaction(fun() -> mnesia:write(?TABLE, Rec, write) end) of
        {atomic, ok} -> ok;
        {aborted, Reason} ->
            ?log_error("memory_tier put failed: ~p", [Reason]),
            {error, Reason}
    end.

do_delete(SessionId, Tier, Key) ->
    MemId = make_mem_id(SessionId, Tier, Key),
    case mnesia:transaction(fun() -> mnesia:delete(?TABLE, MemId, write) end) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

get_tier_internal(SessionId, Tier) ->
    case mnesia:transaction(fun() ->
        mnesia:match_object(?TABLE, {?TABLE, '_', SessionId, Tier, '_', '_', '_', '_'}, read)
    end) of
        {atomic, Rows} ->
            Items = [#{tier => T, key => K, content => C, ts => Ts, source => S}
                     || {?TABLE, _Id, _Sess, T, K, C, Ts, S} <- Rows],
            lists:sort(fun(A, B) -> maps:get(ts, A, 0) >= maps:get(ts, B, 0) end, Items);
        {aborted, _} ->
            []
    end.

do_purge_session(SessionId) ->
    case mnesia:transaction(fun() ->
        Rows = mnesia:match_object(?TABLE, {?TABLE, '_', SessionId, '_', '_', '_', '_', '_'}, read),
        lists:foreach(fun(R) ->
            mnesia:delete(?TABLE, element(2, R), write)
        end, Rows),
        length(Rows)
    end) of
        {atomic, N} ->
            ?log("memory_tier purged session=~s entries=~p", [SessionId, N]),
            ok;
        {aborted, Reason} ->
            ?log_warning("memory_tier purge failed session=~s: ~p", [SessionId, Reason]),
            ok
    end.

do_store_extracted(SessionId, Memories) ->
    lists:foreach(fun(Tier) ->
        Items = maps:get(Tier, Memories, []),
        lists:foreach(fun(Item) ->
            Content = maps:get(<<"content">>, Item, maps:get(content, Item, <<>>)),
            case Content of
                <<>> -> ok;
                _ ->
                    Source = maps:get(<<"source">>, Item,
                             maps:get(source, Item, <<"auto_extract">>)),
                    Key = maps:get(<<"key">>, Item,
                          maps:get(key, Item, make_key(Content))),
                    _ = do_put(SessionId, Tier, to_bin(Key), to_bin(Content), to_bin(Source))
            end
        end, Items)
    end, [facts, preferences, workspace]),
    ok.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(_) -> <<>>.

%% 合并同 key 的记忆 (session 层覆盖 global 层)
merge_by_key(Items) ->
    {_, Merged} = lists:foldl(fun(Item, {Seen, Acc}) ->
        Key = maps:get(key, Item, <<>>),
        case sets:is_element(Key, Seen) of
            true -> {Seen, Acc};
            false -> {sets:add_element(Key, Seen), [Item | Acc]}
        end
    end, {sets:new(), []}, Items),
    lists:reverse(Merged).

%%====================================================================
%% 内部: LLM 抽取
%%====================================================================

build_extract_request(History) ->
    %% 只在有 user + assistant 双向对话时才抽取
    HasUser = lists:any(fun(#{role := <<"user">>, content := C}) -> C =/= <<>>;
                           (_) -> false end, History),
    HasAssistant = lists:any(fun(#{role := <<"assistant">>, content := C}) -> byte_size(C) > 20;
                                 (_) -> false end, History),
    case HasUser andalso HasAssistant of
        false -> skip;
        true ->
            Model = application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>),
            SysPrompt = util:u(
                "你是记忆抽取助手。从对话历史中抽取三类信息，输出严格 JSON：\n"
                "1. facts: 用户陈述的事实（名字、技术栈、项目信息）\n"
                "2. preferences: 用户偏好（回答风格、语言、代码风格）\n"
                "3. workspace: 当前工作区/项目的上下文信息\n\n"
                "输出格式: {\"facts\":[{\"content\":\"...\",\"key\":\"语义键\"}],\n"
                "  \"preferences\":[...],\"workspace\":[...]}\n\n"
                "规则:\n"
                "- 只抽取对话中明确出现的信息，不推断不编造\n"
                "- key 是简短语义标识（如 favorite_language），用于去重\n"
                "- 无对应类别输出空数组\n"
                "- 只输出 JSON，不要 Markdown 或解释\n"
                "- content 用中文，简洁精确\n"),
            UserContent = format_history_for_extract(History),
            {ok, #{
                model => Model,
                stream => false,
                tools => [],
                messages => [
                    #{role => <<"system">>, content => SysPrompt},
                    #{role => <<"user">>, content => UserContent}
                ]
            }}
    end.

format_history_for_extract(History) ->
    Msgs = [case M of
        #{role := <<"user">>, content := C} when is_binary(C), C =/= <<>> ->
            <<"用户: ", C/binary>>;
        #{role := <<"assistant">>, content := C} when is_binary(C), C =/= <<>> ->
            Prefix = <<"助手: ">>,
            case byte_size(C) > 500 of
                true ->
                    <<Prefix/binary, (binary:part(C, 0, 500))/binary, "...（截断）">>;
                false ->
                    <<Prefix/binary, C/binary>>
            end;
        _ ->
            <<>>
    end || M <- History],
    NonEmpty = [M || M <- Msgs, M =/= <<>>],
    iolist_to_binary(lists:join(<<"\n">>, lists:sublist(NonEmpty, ?EXTRACT_HISTORY_LIMIT))).

parse_extracted(Content) when is_binary(Content) ->
    JsonText = extract_json(Content),
    case decode_json(JsonText) of
        Map when is_map(Map) ->
            Facts = normalize_items(maps:get(<<"facts">>, Map, [])),
            Prefs = normalize_items(maps:get(<<"preferences">>, Map, [])),
            Ws = normalize_items(maps:get(<<"workspace">>, Map, [])),
            {ok, #{facts => Facts, preferences => Prefs, workspace => Ws}};
        _ ->
            {error, invalid_json}
    end;
parse_extracted(_) ->
    {error, empty_content}.

normalize_items(Items) when is_list(Items) ->
    [I || I <- Items, is_map(I),
          (maps:is_key(<<"content">>, I) orelse maps:is_key(content, I)),
          byte_size(to_bin(maps:get(<<"content">>, I, maps:get(content, I, <<>>)))) > 0];
normalize_items(_) ->
    [].

extract_json(Content) ->
    case {binary:match(Content, <<"{">>), binary:match(Content, <<"}">>, [last])} of
        {{Start, _}, {End, _}} when End >= Start ->
            binary:part(Content, Start, End - Start + 1);
        _ -> Content
    end.

%%====================================================================
%% 内部: 辅助函数
%%====================================================================

make_mem_id(SessionId, Tier, Key) ->
    TierBin = atom_to_binary(Tier, utf8),
    <<SessionId/binary, "::", TierBin/binary, "::", Key/binary>>.

make_key(Content) when is_binary(Content) ->
    Normalized = binary:replace(Content, [<<"\n">>, <<"\r">>, <<"\t">>, <<" ">>, <<"。">>, <<"，">>, <<".">>, <<",">>], <<>>, [global]),
    Hash = erlang:phash2(Normalized, 16#FFFFFFFF),
    iolist_to_binary(io_lib:format("~36.16.0b", [Hash]));
make_key(Content) ->
    make_key(iolist_to_binary(io_lib:format("~p", [Content]))).

has_pending_session(#state{pending = Pending}, SessionId) ->
    lists:any(fun({_Ref, {S, _TRef}}) -> S =:= SessionId end,
              maps:to_list(Pending)).

handle_llm_response(Ref, Response, #state{pending = Pending} = State) ->
    case maps:get(Ref, Pending, undefined) of
        undefined ->
            State;
        {SessionId, TRef} ->
            erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
            Pending1 = maps:remove(Ref, Pending),
            Content = maps:get(content, Response, <<>>),
            case parse_extracted(Content) of
                {ok, Memories} ->
                    do_store_extracted(SessionId, Memories),
                    ?log("memory_tier extracted session=~s counts=~p",
                         [SessionId, [{T, length(Ms)} || {T, Ms} <- maps:to_list(Memories)]]);
                {error, Reason} ->
                    ?log_warning("memory_tier parse failed session=~s: ~p", [SessionId, Reason])
            end,
            State#state{pending = Pending1}
    end.

decode_json(Bin) ->
    case code:which(json) of
        non_existing -> #{};
        _ ->
            try json:decode(Bin)
            catch _:_ -> #{}
            end
    end.
