-module(agent_sup).
-behaviour(supervisor).

-export([start_link/0, start_agent/1, stop_agent/1, init/1]).

%% simple_one_for_one 监督者: 动态拉起 Agent_FSM 进程。
%% 每个 Agent 会话 (一次 ReAct 任务) 对应一个独立的 gen_statem 进程,
%% 互不干扰, 单会话崩溃不影响其他会话。

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 10,
                 period => 10},
    %% transient: 异常退出时监督者自动重启 FSM, 配合 state_store 快照断点续跑 (Phase 3.1)
    ChildSpec = #{id => agent_fsm,
                  start => {agent_fsm, start_link, []},
                  restart => transient,
                  shutdown => 5000,
                  type => worker,
                  modules => [agent_fsm]},
    {ok, {SupFlags, [ChildSpec]}}.

%% 动态启动一个 Agent FSM。
%% Args 示例: [{session_id, <<"sess-1">>}, {model, <<"gpt-4">>}, {tools, [...]}]
%%
%% simple_one_for_one 监督者: child spec 的 start_args = [] 时,
%% supervisor:start_child/2 的第二参数 Args 是「追加到 start_args 之后的参数列表」。
%% 我们希望整个 Args 作为单个参数传给 agent_fsm:start_link/1,
%% 所以必须再套一层 list -> [Args]。
-spec start_agent([{atom(), term()}]) -> {ok, pid()} | {error, term()}.
start_agent(Args) ->
    supervisor:start_child(?MODULE, [Args]).

%% 终止指定 Agent FSM (simple_one_for_one 用 Pid 标识子进程)。
-spec stop_agent(pid()) -> ok | {error, term()}.
stop_agent(Pid) when is_pid(Pid) ->
    case supervisor:terminate_child(?MODULE, Pid) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, Reason} -> {error, Reason}
    end.
