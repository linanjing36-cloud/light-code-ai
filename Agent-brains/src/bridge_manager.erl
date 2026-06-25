-module(bridge_manager).
-behaviour(gen_server).

%%====================================================================
%% Bridge_Manager —— Go 侧 Eion-tools 连接管理器
%%====================================================================
%%
%% 职责:
%%   - 维护与 Go 节点/端口的连接 (分布式节点优先, erlport 端口回退)
%%   - 把业务 Map 经 pb_codec 编码为 Protobuf 二进制后投递给 Go
%%   - 监控 Go 进程存活; nodedown 时通知所有等待中的 FSM ({bridge_disconnect})
%%   - 超时管理: 单次原子请求超时即失败上报, 不在 Go 侧重试 (无状态原则)
%%
%% 接口语义: 全部异步 (cast)。返回 Ref 供 FSM 匹配响应。
%%   call_llm(FsmPid, Req) -> Ref           响应回投 {llm_response, Ref, Resp}
%%   call_tool_batch(FsmPid, ToolCalls) -> ok  每条响应回投 {tool_result, ToolCallId, Resp}
%%
%% 凭证处理: api_base / api_key 由本进程从 app env 注入, 不进入 FSM 状态,
%% 也不经过 context_assembler, 以缩小秘密的暴露面。
%%====================================================================

%% 对外接口
-export([start_link/0, call_llm/2, call_tool_batch/2, call_tool/2]).
%% gen_server 回调
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(Llm_TIMEOUT, 30000).   %% 单次 LLM 推理超时
-define(TOOL_TIMEOUT, 15000).  %% 单次工具执行超时

-record(state, {
    %% Go 节点引用 (分布式节点名; 端口模式时为 port 句柄)
    conn :: node() | port() | undefined,
    %% 等待响应的映射: Ref => {FsmPid, Kind, ReqId}
    %%   Kind = llm | tool ; ReqId = tool_call.id (tool) | undefined (llm)
    pending = #{} :: #{reference() => {pid(), llm | tool, binary() | undefined}}
}).

%%%===================================================================
%%% 对外接口
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% 异步调用 LLM: Req = #{model, messages, tools} (无凭证, 由本进程注入)
call_llm(FsmPid, Req) ->
    Ref = make_ref(),
    gen_server:cast(?MODULE, {call_llm, FsmPid, Ref, Req}),
    Ref.

%% 批量并行派发工具调用 (每个 ToolCall 一条异步请求)
call_tool_batch(FsmPid, ToolCalls) when is_list(ToolCalls) ->
    [call_tool(FsmPid, TC) || TC <- ToolCalls],
    ok.

%% 异步调用单个工具: ToolCall = #{id, name, arguments}
call_tool(FsmPid, #{id := Id, name := Name, arguments := Args}) ->
    Ref = make_ref(),
    gen_server:cast(?MODULE, {call_tool, FsmPid, Ref, Id, Name, Args}),
    Ref.

%%%===================================================================
%%% gen_server 回调
%%%===================================================================

init([]) ->
    %% TODO: 建立与 Go 节点/端口的连接, 并 monitor node
    %%   GoNode = application:get_env(hermes_brains, go_node, 'eion_tools@localhost'),
    %%   net_adm:ping(GoNode), erlang:monitor_node(GoNode, true)
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

handle_cast({call_llm, FsmPid, Ref, Req}, State) ->
    %% 注入凭证 (来自 app env, 不来自 FSM)
    ApiBase = application:get_env(hermes_brains, api_base, <<>>),
    ApiKey = application:get_env(hermes_brains, api_key, <<>>),
    BizReq = Req#{kind => llm_infer,
                  api_base => ApiBase,
                  api_key => ApiKey},
    Payload = pb_codec:encode_req(BizReq),
    %% TODO: 实际向 Go 投递二进制 (端口/分布式节点)
    ok = send_to_go(Payload),
    %% 启动单次请求超时计时器 (Go 侧无状态, 不重试; 超时即失败上报)
    _TimerRef = erlang:start_timer(?Llm_TIMEOUT, self(), {req, Ref}),
    Pending = maps:put(Ref, {FsmPid, llm, undefined}, State#state.pending),
    {noreply, State#state{pending = Pending}};
handle_cast({call_tool, FsmPid, Ref, Id, Name, Args}, State) ->
    BizReq = #{kind => tool_exec,
               req_id => Id,
               tool_name => Name,
               arguments_json => Args},
    Payload = pb_codec:encode_req(BizReq),
    ok = send_to_go(Payload),
    _TimerRef = erlang:start_timer(?TOOL_TIMEOUT, self(), {req, Ref}),
    Pending = maps:put(Ref, {FsmPid, tool, Id}, State#state.pending),
    {noreply, State#state{pending = Pending}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({go_response, Ref, Bin}, State) ->
    %% Go 侧响应回包: 解码后按类型投回对应 FSM
    Resp = pb_codec:decode_resp(Bin),
    case maps:take(Ref, State#state.pending) of
        {{FsmPid, llm, _ReqId}, Pending1} ->
            gen_statem:cast(FsmPid, {llm_response, Ref, Resp}),
            {noreply, State#state{pending = Pending1}};
        {{FsmPid, tool, ReqId}, Pending1} ->
            %% 用 tool_call.id (ReqId) 关联结果, 便于 FSM 组装 tool 角色消息
            gen_statem:cast(FsmPid, {tool_result, ReqId, Resp}),
            {noreply, State#state{pending = Pending1}};
        error ->
            %% 未知/已超时的 Ref: 丢弃
            {noreply, State}
    end;
handle_info({nodedown, _Node}, State) ->
    %% Go 节点掉线: 通知所有等待中的 FSM, 清空 pending
    _ = [gen_statem:cast(FsmPid, {bridge_disconnect})
         || {FsmPid, _Kind, _ReqId} <- maps:values(State#state.pending)],
    {noreply, State#state{pending = #{}, conn = undefined}};
handle_info({timeout, _TimerRef, {req, Ref}}, State) ->
    %% 单次请求超时: 通知对应 FSM 断连语义, 移除 pending 项
    case maps:take(Ref, State#state.pending) of
        {{FsmPid, _Kind, _ReqId}, Pending1} ->
            gen_statem:cast(FsmPid, {bridge_disconnect}),
            {noreply, State#state{pending = Pending1}};
        error ->
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% 内部函数
%%%===================================================================

%% TODO: 实际向 Go 侧发送二进制
%%   分布式节点: {?HERMES_PB_MODULE, decode, ...} 跨节点调用, 或 {go_dispatcher, AgentRequest, Bin}
%%   端口模式: port_command(Port, <<Len:32, Bin/binary>>)
send_to_go(_Payload) ->
    ok.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
