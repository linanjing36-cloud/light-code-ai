-module(pb_codec).

-export([encode_req/1, decode_resp/1, to_struct/1, from_struct/1]).

%%====================================================================
%% pb_codec —— Protobuf 防腐层 (Anti-Corruption Layer)
%%====================================================================
%%
%% 设计原则:
%%   - 业务代码 (agent_fsm / context_assembler / bridge_manager) 只触碰 Erlang Map,
%%     永远不直接调用 hermes 模块 (由 .proto 生成的 gpb 模块)。
%%   - 所有 Map ↔ Protobuf 转换集中在本模块。
%%   - to_struct/1   : 业务 Map -> gpb 消息 Map (供 hermes:encode_msg 使用)
%%   - from_struct/1 : gpb 消息 Map -> 业务 Map (hermes:decode_msg 的产物)
%%
%% 对齐的协议: Agent-brains/proto/hermes.proto (与 Eion-tools 共享同一份契约)
%%   AgentRequest  { oneof payload { LLMInferRequest llm_infer; ToolExecRequest tool_exec; } }
%%   AgentResponse { oneof payload { LLMInferResponse llm_infer; ToolExecResponse tool_exec; } }
%%
%% gpb 5.0 选项 (rebar.config 中 gpb_opts):
%%   - maps / mapfields_as_maps : 消息与 map 字段都用 Erlang Map 表示
%%   - {maps_oneof, flat}       : oneof 字段在 Map 里以 {Tag, Value} 形式呈现，
%%                                即顶层就是 #{llm_infer => InnerMap} 或 #{tool_exec => InnerMap}
%%   - {maps_unset_optional, omitted} : 未设置的 optional 字段不出现在 Map 中
%%   - strings_as_binaries       : 字符串字段用 binary 而非 Erlang list
%%====================================================================

-define(HERMES_PB, hermes).  % 由 rebar3_gpb_plugin 从 proto/hermes.proto 生成 (proto package=hermes)

%%%===================================================================
%%% 对外接口
%%%===================================================================

%% 将业务请求 Map 编码为 AgentRequest 的 Protobuf 二进制。
%%
%% BizReq 形如:
%%   #{kind => llm_infer,  model, api_base, api_key, messages, tools}
%%   #{kind => tool_exec,  req_id, tool_name, arguments_json}
%%   #{kind => capability_list}
%%
%% 返回: binary()  —— 直接发给 Go 侧 (Eion-tools) 的 4 字节长度前缀帧的 protobuf 负载
-spec encode_req(map()) -> binary().
encode_req(BizReq) when is_map(BizReq) ->
    AgentReq = to_struct(BizReq),
    ?HERMES_PB:encode_msg(AgentReq, 'AgentRequest').

%% 将 AgentResponse 的 Protobuf 二进制解码为业务响应 Map。
%%
%% 返回形如:
%%   #{kind => llm_infer, content, tool_calls, prompt_tokens, completion_tokens, reasoning_content}
%%   #{kind => tool_exec, result_json, error}
%%   #{kind => capability_list, capabilities, error}
%%
%% 注: reasoning_content 来自 v4-pro 等推理模型，正文仍在 content。
-spec decode_resp(binary()) -> map().
decode_resp(Bin) when is_binary(Bin) ->
    Resp = ?HERMES_PB:decode_msg(Bin, 'AgentResponse'),
    from_struct(Resp).

%%%===================================================================
%%% 业务 Map -> gpb 消息 Map (to_struct)
%%%
%%% gpb 在 {maps_oneof, flat} 选项下:
%%%   - 顶层 AgentRequest 表示为 #{llm_infer => LlmReq} 或 #{tool_exec => ToolReq}
%%%   - 内层消息的字段名是 atom，缺失字段不出现在 Map 中
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
               tools => Tools,
               %% Task 4: stream=true 让 Go 侧用 Eino Stream API 按 chunk 流式输出
               stream => maps:get(stream, M, false)},
    #{llm_infer => LlmReq};
to_struct(#{kind := tool_exec} = M) ->
    %% ToolExecRequest 包装进 AgentRequest.tool_exec
    ToolReq = #{req_id => maps:get(req_id, M, <<>>),
                tool_name => maps:get(tool_name, M, <<>>),
                arguments_json => maps:get(arguments_json, M, <<>>)},
    #{tool_exec => ToolReq};
to_struct(#{kind := capability_list}) ->
    #{capability_list => #{}};
to_struct(#{kind := tool_list}) ->
    #{tool_list => #{}}.

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

tool_desc_from_struct(T) ->
    #{name => maps:get(name, T, <<>>),
      description => maps:get(description, T, <<>>),
      parameters_json => maps:get(parameters_json, T, <<>>)}.

capability_desc_from_struct(C) ->
    #{name => maps:get(name, C, <<>>),
      kind => maps:get(kind, C, <<>>),
      source => maps:get(source, C, <<>>),
      version => maps:get(version, C, <<>>),
      description => maps:get(description, C, <<>>),
      input_schema_json => maps:get(input_schema_json, C, <<>>),
      output_schema_json => maps:get(output_schema_json, C, <<>>),
      streaming => maps:get(streaming, C, false),
      risk_level => maps:get(risk_level, C, <<>>),
      cost_hint => maps:get(cost_hint, C, <<>>),
      tags => maps:get(tags, C, [])}.

%%%===================================================================
%%% gpb 消息 Map -> 业务 Map (from_struct)
%%%
%%% gpb 解码出的顶层 AgentResponse 在 {maps_oneof, flat} 选项下形如:
%%%   #{llm_infer => InnerMap}  -> 走 LLM 响应分支
%%%   #{tool_exec => InnerMap}  -> 走 工具响应分支
%%% 内层 InnerMap 的字段名是 atom，缺失字段不在 Map 中（需用 maps:get 带默认值兜底）
%%%===================================================================

-spec from_struct(map()) -> map().
from_struct(#{llm_infer := Resp}) ->
    %% LLMInferResponse 分支 (终态: stream=true 时的最终响应, 或 stream=false 的完整响应)
    %% 注意: reasoning_content 是 v4-pro 推理模型新增字段，可能在普通模型响应中缺失
    #{kind => llm_infer,
      content => maps:get(content, Resp, <<>>),
      tool_calls => [tool_call_from_struct(TC) || TC <- maps:get(tool_calls, Resp, [])],
      prompt_tokens => maps:get(prompt_tokens, Resp, 0),
      completion_tokens => maps:get(completion_tokens, Resp, 0),
      reasoning_content => maps:get(reasoning_content, Resp, <<>>)};
from_struct(#{llm_chunk := Chunk}) ->
    %% Task 4: LlmChunk 流式增量 (非终态, 紧随其后必有 llm_infer 终态)
    %% bridge_manager 收到后转发 {llm_chunk, Ref, ChunkMap} 给 FSM, 不释放连接
    #{kind => llm_chunk,
      content => maps:get(content, Chunk, <<>>),
      reasoning_content => maps:get(reasoning_content, Chunk, <<>>)};
from_struct(#{tool_exec := Resp}) ->
    %% ToolExecResponse 分支 (error 非空表示失败)
    #{kind => tool_exec,
      result_json => maps:get(result_json, Resp, <<>>),
      error => maps:get(error, Resp, <<>>)};
from_struct(#{tool_list := Resp}) ->
    Tools = [tool_desc_from_struct(T) || T <- maps:get(tools, Resp, [])],
    #{kind => tool_list,
      tools => Tools,
      error => maps:get(error, Resp, <<>>)};
from_struct(#{capability_list := Resp}) ->
    Caps = [capability_desc_from_struct(C) || C <- maps:get(capabilities, Resp, [])],
    #{kind => capability_list,
      capabilities => Caps,
      error => maps:get(error, Resp, <<>>) };
from_struct(Other) ->
    %% 防御性兜底: 未知结构 (例如 Go 侧返回空 oneof 时 gpb 解出 #{})
    %% 直接原样返回，让调用方按需处理
    Other.

%% ToolCall gpb map -> 业务 Map
tool_call_from_struct(TC) ->
    #{id => maps:get(id, TC, <<>>),
      name => maps:get(name, TC, <<>>),
      arguments => maps:get(arguments, TC, <<>>)}.
