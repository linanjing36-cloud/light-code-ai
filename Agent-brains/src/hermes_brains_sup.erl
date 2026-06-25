-module(hermes_brains_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(SERVER, ?MODULE).

%% 顶层监督者: rest_for_one 策略。
%%
%% 子进程顺序: state_store (ETS 持有者) -> agent_sup (动态 FSM 监督者)
%% 选择 rest_for_one 的理由:
%%   state_store 崩溃意味着 ETS 表丢失, 其上所有 FSM 的快照/历史也随之失效,
%%   因此 agent_sup 及其下所有 FSM 必须一起重启 (可从持久层恢复快照)。
%%   反之 agent_sup 崩溃不会影响 state_store 的 ETS 表。

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => rest_for_one,
                 intensity => 5,
                 period => 10},

    %% ETS 持有者: 存放 FSM 快照 + 短期记忆
    StateStore = #{id => state_store,
                   start => {state_store, start_link, []},
                   restart => permanent,
                   shutdown => 5000,
                   type => worker,
                   modules => [state_store]},

    %% 动态 FSM 监督者 (simple_one_for_one): 每个 Agent 会话 = 一个 FSM 进程
    AgentSup = #{id => agent_sup,
                 start => {agent_sup, start_link, []},
                 restart => permanent,
                 shutdown => infinity,
                 type => supervisor,
                 modules => [agent_sup]},

    {ok, {SupFlags, [StateStore, AgentSup]}}.
