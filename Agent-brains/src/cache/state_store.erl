-module(state_store).
-behaviour(gen_server).

%%====================================================================
%% State_Store —— 系统级 ETS 持有者 (快照 + 短期记忆)
%%====================================================================
%%
%% 职责:
%%   - 持有 ETS 表 (named, public, read_concurrency), 供 FSM 读写
%%   - 存放 FSM 快照 (session_id => #data{}), 用于崩溃恢复
%%   - 存放按会话分组的短期记忆 (session_id => [Message])
%%
%% 作为顶层监督者的子进程, 其崩溃会触发 rest_for_one 重启 (ETS 随之重建)。
%%====================================================================

%% 对外接口
-export([start_link/0,
         put_snapshot/2, get_snapshot/1,
         append_history/2, get_history/1]).
%% gen_server 回调
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TABLE, hermes_brains_state).

-record(state, {}).

%%%===================================================================
%%% 对外接口
%%%===================================================================

start_link() ->
    cache:init_table_config(),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% 落 FSM 快照 (崩溃恢复用)
put_snapshot(SessionId, Data) ->
    gen_server:call(?MODULE, {put_snapshot, SessionId, Data}).

get_snapshot(SessionId) ->
    gen_server:call(?MODULE, {get_snapshot, SessionId}).

%% 追加短期记忆 (按会话): 维护一个倒序表, 读取时反转为正序
append_history(SessionId, Message) ->
    gen_server:call(?MODULE, {append_history, SessionId, Message}).

get_history(SessionId) ->
    gen_server:call(?MODULE, {get_history, SessionId}).

%%%===================================================================
%%% gen_server 回调
%%%===================================================================

init([]) ->
    %% named_table: 让 FSM/其他进程可并发读; 写入经本 GenServer 串行化
    ets:new(?TABLE, [set, public, named_table, {read_concurrency, true}]),
    {ok, #state{}}.

handle_call({put_snapshot, SessionId, Data}, _From, State) ->
    ets:insert(?TABLE, {{snapshot, SessionId}, Data}),
    {reply, ok, State};
handle_call({get_snapshot, SessionId}, _From, State) ->
    case ets:lookup(?TABLE, {snapshot, SessionId}) of
        [{{snapshot, SessionId}, Data}] -> {reply, {ok, Data}, State};
        [] -> {reply, not_found, State}
    end;
handle_call({append_history, SessionId, Message}, _From, State) ->
    Current = case ets:lookup(?TABLE, {history, SessionId}) of
                  [{{history, SessionId}, Msgs}] -> Msgs;
                  [] -> []
              end,
    %% 头插 (O(1)); 读取时反转
    ets:insert(?TABLE, {{history, SessionId}, [Message | Current]}),
    {reply, ok, State};
handle_call({get_history, SessionId}, _From, State) ->
    case ets:lookup(?TABLE, {history, SessionId}) of
        [{{history, SessionId}, Msgs}] -> {reply, {ok, lists:reverse(Msgs)}, State};
        [] -> {reply, {ok, []}, State}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
