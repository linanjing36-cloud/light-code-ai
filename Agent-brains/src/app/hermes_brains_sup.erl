-module(hermes_brains_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(SERVER, ?MODULE).

%% 顶层监督者: rest_for_one 策略。
%%
%% 子进程顺序: timing_wheel -> mnesia_store -> state_store -> bridge_manager -> agent_sup -> case_store
%% 选择 rest_for_one 的理由:
%%   - timing_wheel 崩溃 → 所有周期/一次性事件丢失, mnesia_store 的 snapshot tick
%%     也来自这里, 所以后续全部要重启重新注册 timer。
%%   - mnesia_store 崩溃 → 磁盘层失效, state_store 后续的 restore/snapshot 都不可信,
%%     后续全部重启。
%%   - state_store 崩溃意味着 ETS 表丢失, 其上所有 FSM 的快照/历史也随之失效,
%%     因此 bridge_manager / agent_sup 及其下所有 FSM 必须一起重启
%%     (state_store 重启后会从 mnesia_store 恢复 ETS 快照)。
%%   - 反之 agent_sup 崩溃不会影响 state_store 的 ETS 表。
%%   - case_store 置于末尾: 它崩溃仅自重启 (其 Mnesia 表 disc_copies 持久化,
%%     重启不丢数据), 不影响 agent_sup 下面的 FSM。agent_fsm 查询 case_store
%%     走防御性匹配 ({error,_} -> 跳过注入), 所以 case_store 短暂不可用不影响 ReAct。

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => rest_for_one,
                 intensity => 5,
                 period => 10},

    %% Timing_Wheel: 通用时间轮 (用 erlang:start_timer 驱动)
    %% 必须最先启动 —— mnesia_store 的周期 snapshot tick 由它调度
    TimingWheel = #{id => timing_wheel,
                    start => {timing_wheel, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [timing_wheel]},

    %% Mnesia_Store: ETS 快照的磁盘中期存储 (gen_server)
    %% 必须在 state_store 之前启动 —— state_store init 会调 mnesia_store:restore
    %% 把磁盘快照加载回刚创建的 ETS 表, 实现跨重启恢复
    MnesiaStore = #{id => mnesia_store,
                    start => {mnesia_store, start_link, []},
                    restart => permanent,
                    shutdown => 5000,
                    type => worker,
                    modules => [mnesia_store]},

    %% ETS 持有者: 存放 FSM 快照 + 短期记忆
    StateStore = #{id => state_store,
                   start => {state_store, start_link, []},
                   restart => permanent,
                   shutdown => 5000,
                   type => worker,
                   modules => [state_store]},

    %% Bridge_Manager: 与 Go 侧 Eion-tools 的端口连接管理器
    %% 必须在 agent_sup 之前启动 —— FSM 一旦启动就要 call_llm/call_tool
    BridgeManager = #{id => bridge_manager,
                      start => {bridge_manager, start_link, []},
                      restart => permanent,
                      shutdown => 5000,
                      type => worker,
                      modules => [bridge_manager]},

    %% 动态 FSM 监督者 (simple_one_for_one): 每个 Agent 会话 = 一个 FSM 进程
    AgentSup = #{id => agent_sup,
                 start => {agent_sup, start_link, []},
                 restart => permanent,
                 shutdown => infinity,
                 type => supervisor,
                 modules => [agent_sup]},

    %% Case_Store: 失败案例库 (Task 1 负面案例记忆)
    %% 置于末尾: 崩溃仅自重启, 不影响 agent_sup 下的 FSM。
    %% 依赖 mnesia app (mnesia_store 已先行启动), init 调 create_table (幂等)。
    CaseStore = #{id => case_store,
                  start => {case_store, start_link, []},
                  restart => permanent,
                  shutdown => 5000,
                  type => worker,
                  modules => [case_store]},

    %% 启动顺序: timing_wheel -> mnesia_store -> state_store -> bridge_manager -> agent_sup -> case_store
    %% rest_for_one: 任何前置崩溃, 后续全部重启
    {ok, {SupFlags, [TimingWheel, MnesiaStore, StateStore, BridgeManager, AgentSup, CaseStore]}}.
