-module(agent_sup).
-behaviour(supervisor).

-export([start_link/0, start_agent/1, init/1]).

%% simple_one_for_one 监督者: 动态拉起 Agent_FSM 进程。
%% 每个 Agent 会话 (一次 ReAct 任务) 对应一个独立的 gen_statem 进程,
%% 互不干扰, 单会话崩溃不影响其他会话。

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlags = #{strategy => simple_one_for_one,
                 intensity => 10,
                 period => 10},
    %% temporary: 会话 FSM 不自动重启 (会话结束即终止; 崩溃由调用方决定是否重放)
    ChildSpec = #{id => agent_fsm,
                  start => {agent_fsm, start_link, []},
                  restart => temporary,
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
