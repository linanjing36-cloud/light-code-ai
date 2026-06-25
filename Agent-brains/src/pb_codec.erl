-module(pb_codec).

-export([encode_req/1, decode_resp/1, to_struct/1, from_struct/1]).

%%====================================================================
%% pb_codec —— Protobuf 防腐层 (Anti-Corruption Layer)
%%====================================================================
%%
%% 设计原则:
%%   - 业务代码 (agent_fsm / context_assembler / bridge_manager) 只触碰 Erlang Map,
%%     永远不直接调用 hermes_pb (由 .proto 生成的模块)。
%%   - 所有 Map ↔ Protobuf 转换集中在本模块。
%%   - to_struct/1 : 业务 Map -> gpb 消息 Map (供 hermes_pb:encode_msg 使用)
%%   - from_struct/1 : gpb 消息 Map -> 业务 Map (hermes_pb:decode_msg 的产物)
%%
%% 对齐的协议: Eion-tools/proto/hermes.proto
%%   AgentRequest { oneof payload { LLMInferRequest llm_infer; ToolExecRequest tool_exec; } }
%%   AgentResponse { oneof payload { LLMInferResponse llm_infer; ToolExecResponse tool_exec; } }
%%
%% 注: 该 proto 使用具体消息类型 (而非 google.protobuf.Struct)。
%% 这里的 "struct" 指 gpb 生成的结构化消息 Map (use_maps:true 下字段为 atom 键)。
%%====================================================================

-define(HERMES_PB, hermes_pb).  % 由 rebar3_gpb 从 proto/hermes.proto 生成

%%%===================================================================
%%% 对外接口
%%%===================================================================

%% 将业务请求 Map 编码为 AgentRequest 的 Protobuf 二进制。
%% BizReq 形如:
%%   #{kind => llm_infer, model, api_base, api_key, messages, tools}
%%   #{kind => tool_exec, req_id, tool_name, arguments_json}
-spec encode_req(map()) -> binary().
encode_req(BizReq) when is_map(BizReq) ->
    AgentReq = to_struct(BizReq),
    %% TODO: dep 拉取后启用 -> ?HERMES_PB:encode_msg(AgentReq, 'AgentRequest')
    _ = AgentReq,
    <<>>.

%% 将 AgentResponse 的 Protobuf 二进制解码为业务响应 Map。
%% 返回形如:
%%   #{kind => llm_infer, content, tool_calls, prompt_tokens, completion_tokens}
%%   #{kind => tool_exec, result_json, error}
-spec decode_resp(binary()) -> map().
decode_resp(_Bin) ->
    %% TODO: dep 拉取后启用 ->
    %%   #{'AgentResponse'} = ?HERMES_PB:decode_msg(Bin, 'AgentResponse'),
    %%   from_struct(Resp)
    #{kind => llm_infer, content => <<>>, tool_calls => [],
      prompt_tokens => 0, completion_tokens => 0}.

%%%===================================================================
%%% 业务 Map -> gpb 消息 Map (to_struct)
%%%===================================================================

-spec to_struct(map()) -> map().
to_struct(#{kind := llm_infer} = M) ->
    %% LLMInferRequest 包装进 AgentRequest.llm_infer
    Messages = [msg_to_struct(Msg) || Msg <- maps:get(messages, M, [])],
    Tools = [tool_desc_to_struct(T) || T <- maps:get(tools, M, [])],
    LlmReq = #{model => maps:get(model, M, <<>>),
               api_base => maps:get(api_base, M, <<>>),
               api_key => maps:get(api_key, M, <<>>),
               messages => Messages,
               tools => Tools},
    #{llm_infer => LlmReq};
to_struct(#{kind := tool_exec} = M) ->
    %% ToolExecRequest 包装进 AgentRequest.tool_exec
    ToolReq = #{req_id => maps:get(req_id, M, <<>>),
                tool_name => maps:get(tool_name, M, <<>>),
                arguments_json => maps:get(arguments_json, M, <<>>)},
    #{tool_exec => ToolReq}.

%% Message -> gpb map (role, content, tool_calls, tool_call_id)
msg_to_struct(Msg) ->
    #{role => maps:get(role, Msg, <<>>),
      content => maps:get(content, Msg, <<>>),
      tool_calls => [tool_call_to_struct(TC) || TC <- maps:get(tool_calls, Msg, [])],
      tool_call_id => maps:get(tool_call_id, Msg, <<>>)}.

%% ToolCall -> gpb map (id, name, arguments)
tool_call_to_struct(TC) ->
    #{id => maps:get(id, TC, <<>>),
      name => maps:get(name, TC, <<>>),
      arguments => maps:get(arguments, TC, <<>>)}.

%% ToolDesc -> gpb map (name, description, parameters_json)
tool_desc_to_struct(T) ->
    #{name => maps:get(name, T, <<>>),
      description => maps:get(description, T, <<>>),
      parameters_json => maps:get(parameters_json, T, <<>>)}.

%%%===================================================================
%%% gpb 消息 Map -> 业务 Map (from_struct)
%%%===================================================================

-spec from_struct(map()) -> map().
from_struct(#{llm_infer := Resp}) ->
    %% LLMInferResponse 分支
    #{kind => llm_infer,
      content => maps:get(content, Resp, <<>>),
      tool_calls => [tool_call_from_struct(TC) || TC <- maps:get(tool_calls, Resp, [])],
      prompt_tokens => maps:get(prompt_tokens, Resp, 0),
      completion_tokens => maps:get(completion_tokens, Resp, 0)};
from_struct(#{tool_exec := Resp}) ->
    %% ToolExecResponse 分支 (error 非空表示失败)
    #{kind => tool_exec,
      result_json => maps:get(result_json, Resp, <<>>),
      error => maps:get(error, Resp, <<>>)};
from_struct(Other) ->
    Other.

%% ToolCall gpb map -> 业务 Map
tool_call_from_struct(TC) ->
    #{id => maps:get(id, TC, <<>>),
      name => maps:get(name, TC, <<>>),
      arguments => maps:get(arguments, TC, <<>>)}.
