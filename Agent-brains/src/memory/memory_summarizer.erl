-module(memory_summarizer).
-behaviour(gen_server).

%% Step 4.1b: 会话轮次结束后异步 LLM 摘要 -> Mnesia session_summaries
-export([start_link/0, schedule/1, schedule_if_long/1, get_recent/2, purge_session/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("log.hrl").

-define(SERVER, ?MODULE).
-define(TABLE, session_summaries).
-define(MAX_PER_SESSION, 20).
-define(MIN_MSGS, 2).
-define(DEFAULT_QUERY_LIMIT, 3).
-define(HISTORY_LEN_THRESHOLD, 20).

-record(state, {
    pending = #{} :: #{reference() => {binary(), non_neg_integer()}}
}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% 轮次结束触发（cast，不阻塞 FSM）
-spec schedule(binary()) -> ok.
schedule(SessionId) when is_binary(SessionId) ->
    gen_server:cast(?SERVER, {schedule, SessionId}),
    ok.

%% history 条数超阈值时触发中期摘要（FSM thinking 前调用，内部去重）
-spec schedule_if_long(binary()) -> ok.
schedule_if_long(SessionId) when is_binary(SessionId) ->
    gen_server:cast(?SERVER, {schedule_if_long, SessionId}),
    ok.

%% 查询某会话最近 N 条摘要（供 context_assembler 注入）
-spec get_recent(binary(), pos_integer()) -> {ok, [map()]} | {error, term()}.
get_recent(SessionId, Limit)
  when is_binary(SessionId), is_integer(Limit), Limit > 0 ->
    gen_server:call(?SERVER, {get_recent, SessionId, Limit}, infinity).

%% 删除会话时: 取消进行中的摘要任务, 清除 Mnesia 中该 session 的全部摘要
-spec purge_session(binary()) -> ok.
purge_session(SessionId) when is_binary(SessionId) ->
    gen_server:cast(?SERVER, {purge_session, SessionId}),
    ok.

init([]) ->
    case create_table() of
        ok ->
            ?log("memory_summarizer started, table=~p", [?TABLE]),
            {ok, #state{}};
        {error, _} = Err ->
            ?log_error("memory_summarizer init failed: ~p", [Err]),
            {stop, Err}
    end.

handle_call({get_recent, SessionId, Limit}, _From, State) ->
    {reply, do_get_recent(SessionId, Limit), State};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({schedule, SessionId}, State) ->
    {noreply, maybe_start_summarize(SessionId, State)};

handle_cast({schedule_if_long, SessionId}, State) ->
    case state_store:get_history(SessionId) of
        {ok, History} when length(History) >= ?HISTORY_LEN_THRESHOLD ->
            case has_pending_session(State, SessionId) of
                true ->
                    {noreply, State};
                false ->
                    {noreply, maybe_start_summarize(SessionId, State)}
            end;
        _ ->
            {noreply, State}
    end;

handle_cast({purge_session, SessionId}, State) ->
    Pending1 = maps:filter(fun(_Ref, {Sess, _Cnt}) -> Sess =/= SessionId end,
                           State#state.pending),
    _ = do_delete_session_summaries(SessionId),
    ?log("memory_summarizer purged session=~s", [SessionId]),
    {noreply, State#state{pending = Pending1}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({llm_response, Ref, Response}, State) ->
    case maps:get(Ref, State#state.pending, undefined) of
        undefined ->
            {noreply, State};
        {SessionId, MsgCount} ->
            Pending1 = maps:remove(Ref, State#state.pending),
            Content = maps:get(content, Response, <<>>),
            case Content of
                <<>> ->
                    ?log_warning("memory_summarizer empty summary session=~s", [SessionId]);
                _ ->
                    ok = do_store(SessionId, Content, MsgCount),
                    ?log("session summary stored session=~s len=~p",
                         [SessionId, byte_size(Content)])
            end,
            {noreply, State#state{pending = Pending1}}
    end;

handle_info({llm_timeout, Ref}, State) ->
    case maps:is_key(Ref, State#state.pending) of
        true ->
            ?log_warning("memory_summarizer llm timeout ref=~p", [Ref]),
            {noreply, State#state{pending = maps:remove(Ref, State#state.pending)}};
        false ->
            {noreply, State}
    end;

handle_info(Msg, State) ->
    case normalize_llm_msg(Msg) of
        {llm_response, Ref, Response} ->
            handle_info({llm_response, Ref, Response}, State);
        _ ->
            {noreply, State}
    end.

normalize_llm_msg({llm_response, Ref, Response}) ->
    {llm_response, Ref, Response};
normalize_llm_msg({'$gen_cast', {llm_response, Ref, Response}}) ->
    {llm_response, Ref, Response};
normalize_llm_msg(_) ->
    unknown.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

create_table() ->
    Node = node(),
    case mnesia:create_table(?TABLE, [
        {attributes, [summary_id, session_id, ts, text, msg_count]},
        {disc_copies, [Node]}
    ]) of
        {atomic, ok} ->
            ?log("session_summaries table created (disc_copies)"),
            ok;
        {aborted, {already_exists, _}} ->
            ok;
        {aborted, Reason} ->
            {error, {create_table_failed, Reason}}
    end.

maybe_start_summarize(SessionId, State) ->
    case state_store:get_history(SessionId) of
        {ok, History} when length(History) >= ?MIN_MSGS ->
            MsgCount = length(History),
            Model = application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>),
            Req = #{
                model => Model,
                stream => false,
                tools => [],
                messages => [
                    #{role => <<"system">>,
                      content => summary_system_prompt()},
                    #{role => <<"user">>,
                      content => format_history_for_summary(History)}
                ]
            },
            Ref = bridge_manager:call_llm(self(), Req),
            Pending1 = maps:put(Ref, {SessionId, MsgCount}, State#state.pending),
            ?log("memory_summarizer llm dispatched session=~s ref=~p msgs=~p",
                 [SessionId, Ref, MsgCount]),
            State#state{pending = Pending1};
        {ok, _} ->
            ?log_trace("memory_summarizer skip session=~s (history too short)", [SessionId]),
            State;
        {error, Reason} ->
            ?log_warning("memory_summarizer no history session=~s reason=~p",
                         [SessionId, Reason]),
            State
    end.

summary_system_prompt() ->
    util:u(
        "你是会话摘要助手。用中文输出 100-300 字的结构化摘要，"
        "保留用户明确说过的关键事实、偏好、决定与待办。"
        "不要编造对话中未出现的信息。只输出摘要正文，不要标题或 Markdown。").

format_history_for_summary(History) ->
    Lines = [format_msg(M) || M <- History],
    iolist_to_binary([util:u("请总结以下对话：\n\n") | Lines]).

format_msg(#{role := Role, content := Content}) ->
    <<(role_label(Role))/binary, ": ", Content/binary, "\n">>;
format_msg(_) ->
    <<>>.

role_label(<<"user">>) -> util:u("用户");
role_label(<<"assistant">>) -> util:u("助手");
role_label(<<"tool">>) -> util:u("工具");
role_label(R) -> R.

do_store(SessionId, Text, MsgCount) ->
    Ts = erlang:system_time(millisecond),
    SummaryId = <<"sum-", SessionId/binary, "-", (integer_to_binary(Ts))/binary>>,
    case mnesia:transaction(fun() ->
        mnesia:write(?TABLE,
                     {?TABLE, SummaryId, SessionId, Ts, Text, MsgCount},
                     write)
    end) of
        {atomic, ok} ->
            _ = maybe_evict_session(SessionId),
            ok;
        {aborted, Reason} ->
            ?log_error("memory_summarizer store failed: ~p", [Reason]),
            {error, Reason}
    end.

do_get_recent(SessionId, Limit) ->
    case mnesia:transaction(fun() ->
        mnesia:match_object(?TABLE, {?TABLE, '_', SessionId, '_', '_', '_'}, read)
    end) of
        {atomic, Rows} ->
            Items = [#{summary_id => Id,
                       session_id => Sess,
                       ts => Ts,
                       text => Text,
                       msg_count => Cnt}
                     || {?TABLE, Id, Sess, Ts, Text, Cnt} <- Rows],
            Sorted = lists:sort(fun(A, B) ->
                maps:get(ts, A, 0) >= maps:get(ts, B, 0)
            end, Items),
            {ok, lists:sublist(Sorted, Limit)};
        {aborted, Reason} ->
            {error, Reason}
    end.

maybe_evict_session(SessionId) ->
    case mnesia:transaction(fun() ->
        Rows = mnesia:match_object(?TABLE, {?TABLE, '_', SessionId, '_', '_', '_'}, read),
        N = length(Rows),
        case N > ?MAX_PER_SESSION of
            true ->
                Sorted = lists:sort(fun({_, _, _, TsA, _, _}, {_, _, _, TsB, _, _}) ->
                    TsA =< TsB
                end, Rows),
                Excess = N - ?MAX_PER_SESSION,
                lists:foreach(fun({?TABLE, Id, _, _, _, _}) ->
                    mnesia:delete(?TABLE, Id, write)
                end, lists:sublist(Sorted, Excess)),
                ok;
            false ->
                ok
        end
    end) of
        {atomic, ok} -> ok;
        _ -> ok
    end.

do_delete_session_summaries(SessionId) ->
    case mnesia:transaction(fun() ->
        Rows = mnesia:match_object(?TABLE, {?TABLE, '_', SessionId, '_', '_', '_'}, read),
        lists:foreach(fun({?TABLE, Id, _, _, _, _}) ->
            mnesia:delete(?TABLE, Id, write)
        end, Rows),
        ok
    end) of
        {atomic, ok} -> ok;
        {aborted, Reason} ->
            ?log_warning("memory_summarizer delete summaries failed session=~s: ~p",
                         [SessionId, Reason]),
            ok
    end.

has_pending_session(#state{pending = Pending}, SessionId) ->
    lists:any(fun({_Ref, {Sess, _Cnt}}) -> Sess =:= SessionId end,
                maps:to_list(Pending)).
