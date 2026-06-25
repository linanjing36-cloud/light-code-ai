-module(timing_wheel).
-behaviour(gen_server).

%%====================================================================
%% Timing_Wheel —— 通用时间轮 (Hashed Wheel) 统一调度所有定时事件
%%====================================================================
%%
%% 设计要点:
%%   - 用 erlang:start_timer(TickMs, self(), tick) 驱动 tick 推进
%%     (而非 erlang:send_after, 二者返回 ref 一致, 但 start_timer 到期发
%%      {timeout, TimerRef, Msg} 元组, 与其他系统 timer 一致, 便于区分)
%%   - wheel_size 个槽环形数组, 每 tick 推进一格, 处理当前槽事件
%%   - 每事件记录 fire_tick, 触发时检查 fire_tick =< current_tick
%%     (这样 wheel_size 较小时, 跨圈事件不会丢失精度, 会延迟到下个圈)
%%   - 周期事件触发后重挂到 current_tick + period_ticks (新槽)
%%   - oneshot 事件触发后从轮上摘除
%%
%% 用途 (统一接管全系统的定时事件):
%%   - mnesia_store: 60s 周期 snapshot ETS 表到磁盘
%%   - bridge_manager: 心跳检测 (未来)
%%   - agent_fsm: max_loops 超时 (未来)
%%   - 任何需要周期/延迟的子系统
%%
%% 用法:
%%   {ok, _} = timing_wheel:start_link(),
%%   %% 周期: 每 60s 给 mnesia_store 进程发 snapshot_tick
%%   Ref1 = timing_wheel:add_periodic(60_000, mnesia_store, snapshot_tick),
%%   %% 一次性: 5s 后给当前进程发 hello
%%   Ref2 = timing_wheel:add_oneshot(5_000, self(), hello),
%%   timing_wheel:cancel(Ref1).
%%
%% 配置 (Options to start_link/1):
%%   {tick_ms,    pos_integer()}  —— tick 精度, 默认 1000ms
%%   {wheel_size, pos_integer()}  —— 槽数, 默认 1024 (约 17min/圈, 跨圈仍准)
%%====================================================================

-export([start_link/0, start_link/1,
         add_oneshot/3, add_periodic/3, cancel/1,
         info/0, stop/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("log.hrl").

-define(SERVER, ?MODULE).
-define(DEFAULT_TICK_MS, 1000).
-define(DEFAULT_WHEEL_SIZE, 1024).

-record(event, {
    ref           :: reference(),
    type          :: oneshot | periodic,
    period_ticks  :: non_neg_integer(),  %% oneshot = 0
    dest          :: pid() | atom(),
    msg           :: term(),
    fire_tick     :: non_neg_integer()
}).

-record(state, {
    tick_ms        :: pos_integer(),
    wheel_size     :: pos_integer(),
    slots          :: array:array([#event{}]),
    current_tick   :: non_neg_integer(),
    timer_ref      :: reference() | undefined,
    events_by_ref  :: #{reference() => #event{}}
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    start_link([]).

start_link(Options) when is_list(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Options, []).

%% 添加一次性定时器: DelayMs 后给 Dest ! Msg (DelayMs=0 表示下个 tick 触发)
-spec add_oneshot(non_neg_integer(), pid() | atom(), term()) -> reference().
add_oneshot(DelayMs, Dest, Msg) when is_integer(DelayMs), DelayMs >= 0 ->
    gen_server:call(?SERVER, {add_oneshot, DelayMs, Dest, Msg}).

%% 添加周期定时器: 第一次触发在 PeriodMs 之后, 之后每 PeriodMs 触发一次
-spec add_periodic(pos_integer(), pid() | atom(), term()) -> reference().
add_periodic(PeriodMs, Dest, Msg) when is_integer(PeriodMs), PeriodMs > 0 ->
    gen_server:call(?SERVER, {add_periodic, PeriodMs, Dest, Msg}).

%% 取消定时器 (oneshot / periodic 都可取消)
-spec cancel(reference()) -> ok | {error, not_found}.
cancel(Ref) ->
    gen_server:call(?SERVER, {cancel, Ref}).

%% 状态查询 (调试用)
-spec info() -> map().
info() ->
    gen_server:call(?SERVER, info).

stop() ->
    gen_server:stop(?SERVER).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Options) ->
    TickMs = proplists:get_value(tick_ms, Options, ?DEFAULT_TICK_MS),
    WheelSize = proplists:get_value(wheel_size, Options, ?DEFAULT_WHEEL_SIZE),
    true = TickMs > 0 andalso WheelSize > 0,  %% 守卫
    Slots = array:new(WheelSize, {default, []}),
    TimerRef = erlang:start_timer(TickMs, self(), tick),
    ?log("timing_wheel started, tick_ms=~p, wheel_size=~p", [TickMs, WheelSize]),
    {ok, #state{tick_ms = TickMs,
                wheel_size = WheelSize,
                slots = Slots,
                current_tick = 0,
                timer_ref = TimerRef,
                events_by_ref = #{}}}.

handle_call({add_oneshot, DelayMs, Dest, Msg}, _From, State) ->
    {Ref, State2} = add_event(oneshot, DelayMs, 0, Dest, Msg, State),
    {reply, Ref, State2};

handle_call({add_periodic, PeriodMs, Dest, Msg}, _From, State) ->
    %% 周期事件: 第一次触发时间 = 一个完整周期之后
    {Ref, State2} = add_event(periodic, PeriodMs, PeriodMs, Dest, Msg, State),
    {reply, Ref, State2};

handle_call({cancel, Ref}, _From, State) ->
    case maps:take(Ref, State#state.events_by_ref) of
        {Event, Events2} ->
            Slots2 = remove_event_from_slot(Event, State#state.slots,
                                            State#state.wheel_size),
            {reply, ok, State#state{slots = Slots2, events_by_ref = Events2}};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call(info, _From, State) ->
    Info = #{tick_ms => State#state.tick_ms,
             wheel_size => State#state.wheel_size,
             current_tick => State#state.current_tick,
             total_events => maps:size(State#state.events_by_ref)},
    {reply, Info, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% tick 推进: 处理当前槽事件, 启动下一个 start_timer
handle_info({timeout, _TRef, tick}, State) ->
    #state{tick_ms = TickMs, wheel_size = WheelSize,
           current_tick = CurTick, slots = Slots,
           events_by_ref = EventsByRef} = S0 = State,
    SlotIdx = CurTick rem WheelSize,
    Events = array:get(SlotIdx, Slots),
    %% 处理槽里的事件: 未到期保留, 到期触发并收集 (周期事件需重挂)
    {Pending, Fired} = process_slot(Events, CurTick),
    Slots2 = array:set(SlotIdx, Pending, Slots),
    %% 重挂周期事件到新槽位, 从 events_by_ref 移除 oneshot
    {Slots3, EventsByRef2} =
        lists:foldl(
            fun(E, {S, EBR}) when E#event.type =:= periodic ->
                    NewFire = CurTick + E#event.period_ticks,
                    E2 = E#event{fire_tick = NewFire},
                    S2 = append_to_slot(E2, S, WheelSize),
                    {S2, EBR#{E2#event.ref => E2}};
               (E, {S, EBR}) ->  %% oneshot: 不重挂, 从 map 删
                    {S, maps:remove(E#event.ref, EBR)}
            end, {Slots2, EventsByRef}, Fired),
    TimerRef = erlang:start_timer(TickMs, self(), tick),
    ?log_trace("tick ~p: slot=~p, fired=~p, active=~p",
               [CurTick, SlotIdx, length(Fired), maps:size(EventsByRef2)]),
    {noreply, S0#state{current_tick = CurTick + 1,
                       slots = Slots3,
                       timer_ref = TimerRef,
                       events_by_ref = EventsByRef2}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal
%%%===================================================================

%% 添加事件: 计算 fire_tick, 挂到对应槽, 入 events_by_ref
add_event(Type, DelayMs, PeriodMs, Dest, Msg, State) ->
    #state{tick_ms = TickMs, wheel_size = WheelSize,
           current_tick = CurTick, slots = Slots,
           events_by_ref = EventsByRef} = State,
    PeriodTicks = max(1, PeriodMs div TickMs),
    DelayTicks = max(1, DelayMs div TickMs),
    FireTick = CurTick + DelayTicks,
    Ref = make_ref(),
    Event = #event{ref = Ref, type = Type,
                   period_ticks = PeriodTicks,
                   dest = Dest, msg = Msg,
                   fire_tick = FireTick},
    Slots2 = append_to_slot(Event, Slots, WheelSize),
    EventsByRef2 = EventsByRef#{Ref => Event},
    {Ref, State#state{slots = Slots2, events_by_ref = EventsByRef2}}.

%% 把事件挂到 fire_tick 对应的槽 (内部辅助)
append_to_slot(Event, Slots, WheelSize) ->
    SlotIdx = Event#event.fire_tick rem WheelSize,
    Old = array:get(SlotIdx, Slots),
    array:set(SlotIdx, [Event | Old], Slots).

%% 从槽中移除事件 (cancel 用)
remove_event_from_slot(Event, Slots, WheelSize) ->
    SlotIdx = Event#event.fire_tick rem WheelSize,
    Old = array:get(SlotIdx, Slots),
    New = [E || E <- Old, E#event.ref =/= Event#event.ref],
    array:set(SlotIdx, New, Slots).

%% 处理一个槽: 未到期事件保留在槽, 到期事件触发并收集 (周期事件稍后重挂)
process_slot(Events, CurTick) ->
    process_slot(Events, CurTick, [], []).

process_slot([], _CurTick, PendingRev, FiredRev) ->
    {lists:reverse(PendingRev), lists:reverse(FiredRev)};
process_slot([E | Rest], CurTick, PendingRev, FiredRev) ->
    case E#event.fire_tick =< CurTick of
        true ->
            send(E#event.dest, E#event.msg),
            process_slot(Rest, CurTick, PendingRev, [E | FiredRev]);
        false ->
            %% 未到期 (跨圈): 保留在当前槽, 等下次扫描再触发
            process_slot(Rest, CurTick, [E | PendingRev], FiredRev)
    end.

%% 安全发送: atom 时 lookup registered name (避免 whereis 返回 undefined 崩溃)
send(Dest, Msg) when is_pid(Dest) ->
    Dest ! Msg;
send(Dest, Msg) when is_atom(Dest) ->
    case whereis(Dest) of
        undefined -> ok;  %% 进程没起来, 静默丢弃 (周期事件下次再试)
        Pid       -> Pid ! Msg
    end.
