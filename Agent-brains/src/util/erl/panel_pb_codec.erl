-module(panel_pb_codec).

%%====================================================================
%% Panel_PB_Codec —— Panel 通道 Protobuf 防腐层
%%====================================================================
%%
%% 设计原则 (与 pb_codec.erl 一致):
%%   - 业务代码 (panel_server) 只触碰 Erlang Map, 永远不直接调用 panel 模块
%%   - 所有 Map ↔ Protobuf 转换集中在本模块
%%   - 业务层无需关心 gpb 的 oneof 平铺 ({maps_oneof, flat}) 细节
%%
%% 协议: Agent-brains/proto/panel.proto (与 Wails-v3/proto/panel.proto 共享同一份契约)
%%   PanelFrame { oneof payload { PanelRequest request; PanelResponse response; PanelStream stream; } }
%%
%% 使用方:
%%   - panel_server (Erlang): pack_request/pack_response/pack_stream_* + unpack_frame
%%   - brain.Bridge (Go) 直接用 protoc-gen-go 生成的 panelpb.PanelFrame (不走本模块)
%%====================================================================

-export([
    %% 编码: 业务 Map -> binary (整帧 PanelFrame)
    pack_request/3,           %% (Id, Method, ArgsMap) -> binary()
    pack_response_ok/3,       %% (Id, Method, ResultMap) -> binary()
    pack_response_err/2,      %% (Id, ErrMsg) -> binary()
    pack_stream_chunk/2,      %% (StreamId, ChunkMap) -> binary()
    pack_stream_tool_event/2, %% (StreamId, EventMap) -> binary()
    pack_stream_final/2,      %% (StreamId, FinalMap) -> binary()
    pack_stream_err/2,        %% (StreamId, ErrMsg) -> binary()
    pack_exec/2,              %% (Id, AgentReqBin) -> binary()
    %% 解码: binary -> 业务级 tagged tuple
    unpack_frame/1            %% (Bin) -> {request, Id, Method, ArgsMap}
                              %%       | {response, Id, ok, ResultBytes}
                              %%       | {response, Id, error, ErrMsg}
                              %%       | {stream, StreamId, StreamPayload}
                              %%       | {exec_result, Id, AgentRespBin, Err, Terminal}
                              %%       | {error, Reason}
]).

%% 仅 panel_server 侧用: 按 method 解码 result_bytes (response 携带的是裸 bytes, 不带 method)
-export([decode_result/2]).

-define(PANEL_PB, panel).  % 由 rebar3_gpb_plugin 从 proto/panel.proto 生成 (proto package=panel)

%%%===================================================================
%%% 编码: 业务 Map -> PanelFrame binary
%%%===================================================================

%% 构造请求帧 (client -> server): PanelFrame{request: PanelRequest{id, method, args_bytes}}
-spec pack_request(non_neg_integer(), binary(), map()) -> binary().
pack_request(Id, Method, ArgsMap) ->
    ArgsBin = encode_args(Method, ArgsMap),
    Frame = #{request => #{id => Id, method => Method, args_bytes => ArgsBin}},
    ?PANEL_PB:encode_msg(Frame, 'PanelFrame').

%% 构造成功响应帧: PanelFrame{response: PanelResponse{id, result_bytes}}
-spec pack_response_ok(non_neg_integer(), binary(), map()) -> binary().
pack_response_ok(Id, Method, ResultMap) ->
    ResultBin = encode_result(Method, ResultMap),
    Frame = #{response => #{id => Id, result_bytes => ResultBin}},
    ?PANEL_PB:encode_msg(Frame, 'PanelFrame').

%% 构造失败响应帧: PanelFrame{response: PanelResponse{id, error}}
-spec pack_response_err(non_neg_integer(), binary()) -> binary().
pack_response_err(Id, ErrMsg) ->
    Frame = #{response => #{id => Id, error => ErrMsg}},
    ?PANEL_PB:encode_msg(Frame, 'PanelFrame').

%% 流式 chunk 帧: PanelFrame{stream: PanelStream{stream_id, chunk}}
-spec pack_stream_chunk(binary(), map()) -> binary().
pack_stream_chunk(StreamId, ChunkMap) ->
    Inner = #{stream_id => StreamId,
              chunk => #{content => maps:get(content, ChunkMap, <<>>),
                         reasoning_content => maps:get(reasoning_content, ChunkMap, <<>>)}},
    ?PANEL_PB:encode_msg(#{stream => Inner}, 'PanelFrame').

%% 工具事件帧
-spec pack_stream_tool_event(binary(), map()) -> binary().
pack_stream_tool_event(StreamId, EvMap) ->
    ToolEvent0 = #{tool_call_id => maps:get(tool_call_id, EvMap, <<>>),
                   name => maps:get(name, EvMap, <<>>),
                   error => maps:get(error, EvMap, <<>>),
                   finished => maps:get(finished, EvMap, false)},
    ToolEvent1 = maybe_put_json_value(arguments, maps:get(arguments_json, EvMap, <<>>), ToolEvent0),
    ToolEvent2 = maybe_put_json_value(result, maps:get(result_json, EvMap, <<>>), ToolEvent1),
    Inner = #{stream_id => StreamId, tool_event => ToolEvent2},
    ?PANEL_PB:encode_msg(#{stream => Inner}, 'PanelFrame').

%% 最终答案帧 (终态)
-spec pack_stream_final(binary(), map()) -> binary().
pack_stream_final(StreamId, FinalMap) ->
    Inner = #{stream_id => StreamId,
              final => #{content => maps:get(content, FinalMap, <<>>),
                         prompt_tokens => maps:get(prompt_tokens, FinalMap, 0),
                         completion_tokens => maps:get(completion_tokens, FinalMap, 0),
                         loop_count => maps:get(loop_count, FinalMap, 0)}},
    ?PANEL_PB:encode_msg(#{stream => Inner}, 'PanelFrame').

%% 流式错误帧 (终态)
-spec pack_stream_err(binary(), binary()) -> binary().
pack_stream_err(StreamId, ErrMsg) ->
    Inner = #{stream_id => StreamId,
              error => #{message => ErrMsg}},
    ?PANEL_PB:encode_msg(#{stream => Inner}, 'PanelFrame').

%% Phase B: Erlang 经 panel 连接让 Wails 进程内执行 hermes AgentRequest
-spec pack_exec(non_neg_integer(), binary()) -> binary().
pack_exec(Id, AgentReqBin) ->
    Frame = #{exec => #{id => Id, agent_request => AgentReqBin}},
    ?PANEL_PB:encode_msg(Frame, 'PanelFrame').

%%%===================================================================
%%% 解码: binary -> 业务级 tagged tuple
%%%===================================================================

%% 解码整帧 PanelFrame, 按 oneof 分支返回不同 tagged tuple。
%%
%% 返回值:
%%   {request, Id, Method, ArgsMap}                 客户端请求
%%   {response, Id, ok, ResultBytes}                成功响应 (client 侧需自维护 id->method 映射来 decode ResultBytes)
%%   {response, Id, error, ErrMsg}                  失败响应
%%   {stream, StreamId, {chunk|tool_event|final|error, Map}}  流式 push 帧
%%   {error, Reason}                                 无法识别的帧
-spec unpack_frame(binary()) ->
    {request, non_neg_integer(), binary(), map()} |
    {response, non_neg_integer(), ok, binary()} |
    {response, non_neg_integer(), error, binary()} |
    {stream, binary(), {chunk | tool_event | final | error, map()}} |
    {exec_result, non_neg_integer(), binary(), binary(), boolean()} |
    {error, term()}.
unpack_frame(Bin) ->
    try ?PANEL_PB:decode_msg(Bin, 'PanelFrame') of
        Frame when is_map(Frame) ->
            decode_frame_map(Frame)
    catch
        Class:Reason ->
            {error, {decode_failed, Class, Reason}}
    end.

decode_frame_map(Frame) ->
    %% gpb {maps_oneof, flat}: PanelFrame Map 直接含 request/response/stream 键 (最多一个非 undefined)
    IsReq = maps:is_key(request, Frame),
    IsResp = maps:is_key(response, Frame),
    IsStream = maps:is_key(stream, Frame),
    IsExecResult = maps:is_key(exec_result, Frame),
    if
        IsReq -> decode_request(maps:get(request, Frame));
        IsResp -> decode_response(maps:get(response, Frame));
        IsStream -> decode_stream(maps:get(stream, Frame));
        IsExecResult -> decode_exec_result(maps:get(exec_result, Frame));
        true -> {error, empty_frame}
    end.

%% PanelRequest -> {request, Id, Method, ArgsMap}
decode_request(Req) ->
    Id = maps:get(id, Req, 0),
    Method = maps:get(method, Req, <<>>),
    ArgsBin = maps:get(args_bytes, Req, <<>>),
    ArgsMap = decode_args(Method, ArgsBin),
    {request, Id, Method, ArgsMap}.

%% PanelResponse -> {response, Id, ok, ResultBytes} | {response, Id, error, ErrMsg}
%% 注: 不在此处按 method 解码 result_bytes —— client 侧才知道自己发的什么 method
decode_response(Resp) ->
    Id = maps:get(id, Resp, 0),
    case maps:is_key(error, Resp) of
        true ->
            ErrMsg = maps:get(error, Resp, <<>>),
            {response, Id, error, ErrMsg};
        false ->
            ResultBin = maps:get(result_bytes, Resp, <<>>),
            {response, Id, ok, ResultBin}
    end.

%% PanelStream -> {stream, StreamId, {Tag, Map}}
decode_stream(Stream) ->
    StreamId = maps:get(stream_id, Stream, <<>>),
    case maps:is_key(chunk, Stream) of
        true ->
            Chunk = maps:get(chunk, Stream),
            {stream, StreamId, {chunk, #{content => maps:get(content, Chunk, <<>>),
                                          reasoning_content => maps:get(reasoning_content, Chunk, <<>>)}}};
        false ->
            case maps:is_key(tool_event, Stream) of
                true ->
                    Ev = maps:get(tool_event, Stream),
                    BaseEv = #{tool_call_id => maps:get(tool_call_id, Ev, <<>>),
                               name => maps:get(name, Ev, <<>>),
                               error => maps:get(error, Ev, <<>>),
                               finished => maps:get(finished, Ev, false)},
                    WithArgs = maybe_put_json_binary(arguments_json, maps:get(arguments, Ev, undefined), BaseEv),
                    WithResult = maybe_put_json_binary(result_json, maps:get(result, Ev, undefined), WithArgs),
                    {stream, StreamId, {tool_event, WithResult}};
                false ->
                    case maps:is_key(final, Stream) of
                        true ->
                            F = maps:get(final, Stream),
                            {stream, StreamId, {final,
                                #{content => maps:get(content, F, <<>>),
                                  prompt_tokens => maps:get(prompt_tokens, F, 0),
                                  completion_tokens => maps:get(completion_tokens, F, 0),
                                  loop_count => maps:get(loop_count, F, 0)}}};
                        false ->
                            case maps:is_key(error, Stream) of
                                true ->
                                    Err = maps:get(error, Stream),
                                    {stream, StreamId, {error, #{message => maps:get(message, Err, <<>>)}}};
                                false ->
                                    {stream, StreamId, {unknown, #{}}}
                            end
                    end
            end
    end.

%% PanelExecResult -> {exec_result, Id, AgentRespBin, Err, Terminal}
decode_exec_result(R) ->
    Id = maps:get(id, R, 0),
    AgentResp = maps:get(agent_response, R, <<>>),
    Err = maps:get(error, R, <<>>),
    Terminal = maps:get(terminal, R, false),
    {exec_result, Id, AgentResp, Err, Terminal}.

%%%===================================================================
%%% 按 method 路由的 Args/Result 编解码
%%%===================================================================

%% ---- Args (request) ----
encode_args(<<"start_session">>, Args) ->
    ?PANEL_PB:encode_msg(#{
        system_prompt => maps:get(system_prompt, Args, <<>>),
        model => maps:get(model, Args, <<>>),
        api_key => maps:get(api_key, Args, <<>>),
        api_base => maps:get(api_base, Args, <<>>)
    }, 'StartSessionArgs');
encode_args(<<"send">>, #{session_id := SessId, message := Msg}) ->
    ?PANEL_PB:encode_msg(#{session_id => SessId, message => Msg}, 'SendArgs');
encode_args(<<"approve">>, #{req_id := ReqId, allow := Allow}) ->
    ?PANEL_PB:encode_msg(#{req_id => ReqId, allow => Allow}, 'ApproveArgs');
encode_args(<<"brain_status">>, #{session_id := SessId}) ->
    ?PANEL_PB:encode_msg(#{session_id => SessId}, 'BrainStatusArgs');
encode_args(<<"get_history">>, #{session_id := SessId}) ->
    ?PANEL_PB:encode_msg(#{session_id => SessId}, 'GetHistoryArgs');
encode_args(<<"delete_session">>, #{session_id := SessId}) ->
    ?PANEL_PB:encode_msg(#{session_id => SessId}, 'DeleteSessionArgs');
encode_args(_NoArgsMethod, _ArgsMap) ->
    %% list_tools / stop 无参数, args_bytes 为空
    <<>>.

decode_args(<<"start_session">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'StartSessionArgs'),
    #{system_prompt => maps:get(system_prompt, M, <<>>),
      model => maps:get(model, M, <<>>),
      api_key => maps:get(api_key, M, <<>>),
      api_base => maps:get(api_base, M, <<>>)};
decode_args(<<"send">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'SendArgs'),
    #{session_id => maps:get(session_id, M, <<>>),
      message => maps:get(message, M, <<>>)};
decode_args(<<"approve">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'ApproveArgs'),
    #{req_id => maps:get(req_id, M, <<>>),
      allow => maps:get(allow, M, false)};
decode_args(<<"brain_status">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'BrainStatusArgs'),
    #{session_id => maps:get(session_id, M, <<>>)};
decode_args(<<"get_history">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'GetHistoryArgs'),
    #{session_id => maps:get(session_id, M, <<>>)};
decode_args(<<"delete_session">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'DeleteSessionArgs'),
    #{session_id => maps:get(session_id, M, <<>>)};
decode_args(_NoArgsMethod, _Bin) ->
    #{}.

%% ---- Result (response) ----
encode_result(<<"start_session">>, #{session_id := SessId}) ->
    ?PANEL_PB:encode_msg(#{session_id => SessId}, 'StartSessionResult');
encode_result(<<"send">>, #{stream_id := StreamId}) ->
    ?PANEL_PB:encode_msg(#{stream_id => StreamId}, 'SendResult');
encode_result(<<"list_tools">>, #{tools := Tools}) ->
    PbTools = [tool_desc_to_pb(T) || T <- Tools],
    ?PANEL_PB:encode_msg(#{tools => PbTools}, 'ListToolsResult');
encode_result(<<"approve">>, #{ok := Ok}) ->
    ?PANEL_PB:encode_msg(#{ok => Ok}, 'ApproveResult');
encode_result(<<"brain_status">>, M) ->
    StateBin = encode_state_bin(maps:get(state, M, <<>>)),
    PbM = #{state => StateBin,
            loop_count => maps:get(loop_count, M, 0),
            max_loops => maps:get(max_loops, M, 0),
            history_len => maps:get(history_len, M, 0)},
    ?PANEL_PB:encode_msg(PbM, 'BrainStatusResult');
encode_result(<<"get_history">>, #{messages := Msgs}) ->
    PbMsgs = [history_entry_to_pb(M) || M <- Msgs],
    ?PANEL_PB:encode_msg(#{messages => PbMsgs}, 'GetHistoryResult');
encode_result(<<"stop">>, #{ok := Ok}) ->
    ?PANEL_PB:encode_msg(#{ok => Ok}, 'StopResult');
encode_result(<<"delete_session">>, #{ok := Ok}) ->
    ?PANEL_PB:encode_msg(#{ok => Ok}, 'DeleteSessionResult');
encode_result(_Method, _ResultMap) ->
    <<>>.

-spec decode_result(binary(), binary()) -> map().
decode_result(<<"start_session">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'StartSessionResult'),
    #{session_id => maps:get(session_id, M, <<>>)};
decode_result(<<"send">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'SendResult'),
    #{stream_id => maps:get(stream_id, M, <<>>)};
decode_result(<<"list_tools">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'ListToolsResult'),
    #{tools => [tool_desc_from_pb(T) || T <- maps:get(tools, M, [])]};
decode_result(<<"approve">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'ApproveResult'),
    #{ok => maps:get(ok, M, false)};
decode_result(<<"brain_status">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'BrainStatusResult'),
    #{state => maps:get(state, M, <<>>),
      loop_count => maps:get(loop_count, M, 0),
      max_loops => maps:get(max_loops, M, 0),
      history_len => maps:get(history_len, M, 0)};
decode_result(<<"get_history">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'GetHistoryResult'),
    #{messages => [history_entry_from_pb(E) || E <- maps:get(messages, M, [])]};
decode_result(<<"stop">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'StopResult'),
    #{ok => maps:get(ok, M, false)};
decode_result(<<"delete_session">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'DeleteSessionResult'),
    #{ok => maps:get(ok, M, false)};
decode_result(_Method, _Bin) ->
    #{}.

encode_state_bin(S) when is_atom(S) -> atom_to_binary(S, utf8);
encode_state_bin(S) when is_binary(S) -> S;
encode_state_bin(S) when is_list(S) -> list_to_binary(S);
encode_state_bin(_) -> <<>>.

history_entry_to_pb(M) ->
    Role = ensure_binary(maps:get(role, M, <<>>)),
    Content = ensure_binary(maps:get(content, M, <<>>)),
    ToolCalls = [tool_call_to_pb(TC) || TC <- maps:get(tool_calls, M, [])],
    ToolCallId = ensure_binary(maps:get(tool_call_id, M, <<>>)),
    #{role => Role,
      content => Content,
      tool_calls => ToolCalls,
      tool_call_id => ToolCallId}.

history_entry_from_pb(E) ->
    Base = #{role => maps:get(role, E, <<>>),
             content => maps:get(content, E, <<>>)},
    ToolCalls = [tool_call_from_pb(TC) || TC <- maps:get(tool_calls, E, [])],
    WithTC = case ToolCalls of
                 [] -> Base;
                 _ -> Base#{tool_calls => ToolCalls}
             end,
    ToolCallId = maps:get(tool_call_id, E, <<>>),
    case ToolCallId of
        <<>> -> WithTC;
        _ -> WithTC#{tool_call_id => ToolCallId}
    end.

tool_desc_to_pb(T) ->
    Base = #{name => maps:get(name, T, <<>>),
             description => maps:get(description, T, <<>>)},
    maybe_put_tool_parameters_pb(parameters_pb, maps:get(parameters_json, T, <<>>), Base).

tool_desc_from_pb(T) ->
    Base = #{name => maps:get(name, T, <<>>),
             description => maps:get(description, T, <<>>)},
    maybe_put_tool_parameters_json(parameters_json, maps:get(parameters_pb, T, undefined), Base).

tool_call_to_pb(TC) ->
    Fun0 = #{name => ensure_binary(maps:get(name, TC, <<>>))},
    Fun1 = maybe_put_json_value(arguments, maps:get(arguments, TC, <<>>), Fun0),
    #{id => ensure_binary(maps:get(id, TC, <<>>)),
      type => ensure_binary(maps:get(type, TC, <<"function">>)),
      function => Fun1}.

tool_call_from_pb(TC) ->
    Fun = maps:get(function, TC, #{}),
    Base = #{id => maps:get(id, TC, <<>>),
             name => maps:get(name, Fun, <<>>)},
    maybe_put_json_binary(arguments, maps:get(arguments, Fun, undefined), Base).

maybe_put_json_value(_Key, <<>>, Map) ->
    Map;
maybe_put_json_value(_Key, undefined, Map) ->
    Map;
maybe_put_json_value(Key, JsonBin, Map) ->
    case json_value_from_json_binary(JsonBin) of
        undefined -> Map;
        JsonValue -> Map#{Key => JsonValue}
    end.

maybe_put_json_binary(_Key, undefined, Map) ->
    Map;
maybe_put_json_binary(Key, JsonValue, Map) ->
    case json_value_to_binary_json(JsonValue) of
        undefined -> Map;
        JsonBin -> Map#{Key => JsonBin}
    end.

maybe_put_tool_parameters_json(_Key, undefined, Map) ->
    Map;
maybe_put_tool_parameters_json(Key, ToolParametersPb, Map) ->
    case tool_parameters_from_pb_binary(ToolParametersPb) of
        undefined -> Map;
        ToolParameters ->
            case tool_parameters_to_binary_json(ToolParameters) of
                undefined -> Map;
                JsonBin -> Map#{Key => JsonBin}
            end
    end.

maybe_put_tool_parameters_pb(_Key, <<>>, Map) ->
    Map;
maybe_put_tool_parameters_pb(_Key, undefined, Map) ->
    Map;
maybe_put_tool_parameters_pb(Key, JsonBin, Map) ->
    case tool_parameters_from_json_binary(JsonBin) of
        undefined -> Map;
        ToolParameters ->
            case tool_parameters_to_pb_binary(ToolParameters) of
                undefined -> Map;
                PbBin -> Map#{Key => PbBin}
            end
    end.

tool_parameters_to_pb_binary(undefined) ->
    undefined;
tool_parameters_to_pb_binary(ToolParameters) ->
    ?PANEL_PB:encode_msg(ToolParameters, 'ToolParameters').

tool_parameters_from_pb_binary(<<>>) ->
    undefined;
tool_parameters_from_pb_binary(undefined) ->
    undefined;
tool_parameters_from_pb_binary(Bin) ->
    try ?PANEL_PB:decode_msg(Bin, 'ToolParameters') of
        Decoded -> Decoded
    catch
        _:_ -> undefined
    end.

json_value_from_json_binary(JsonBin) ->
    try
        json_value_from_term(json:decode(ensure_binary(JsonBin)))
    catch
        _:_ -> undefined
    end.

json_value_from_term(null) ->
    #{null_value => true};
json_value_from_term(V) when is_binary(V) ->
    #{string_value => V};
json_value_from_term(V) when is_boolean(V) ->
    #{bool_value => V};
json_value_from_term(V) when is_integer(V) ->
    #{number_value => float(V)};
json_value_from_term(V) when is_float(V) ->
    #{number_value => V};
json_value_from_term(V) when is_map(V) ->
    Fields = [#{key => ensure_binary(K), value => json_value_from_term(Val)}
              || {K, Val} <- maps:to_list(V)],
    #{object_value => #{fields => Fields}};
json_value_from_term(V) when is_list(V) ->
    case is_string_list(V) of
        true ->
            #{string_value => ensure_binary(V)};
        false ->
            #{array_value => #{items => [json_value_from_term(Item) || Item <- V]}}
    end.

json_value_to_binary_json(undefined) ->
    undefined;
json_value_to_binary_json(JsonValue) ->
    json:encode(json_value_to_term(JsonValue)).

tool_parameters_from_json_binary(JsonBin) ->
    try
        tool_parameters_from_term(json:decode(ensure_binary(JsonBin)))
    catch
        _:_ -> undefined
    end.

tool_parameters_from_term(Term) when is_map(Term) ->
    Type = ensure_binary(maps:get(<<"type">>, Term, <<"object">>)),
    PropertiesMap = maps:get(<<"properties">>, Term, #{}),
    RequiredNames = maps:get(<<"required">>, Term, []),
    RequiredSet = maps:from_list([{ensure_binary(Name), true} || Name <- RequiredNames]),
    Properties = [tool_parameter_from_term(Name, Spec, RequiredSet)
                  || {Name, Spec} <- maps:to_list(PropertiesMap)],
    #{type => Type, properties => Properties};
tool_parameters_from_term(_) ->
    undefined.

tool_parameter_from_term(Name, Spec, RequiredSet) when is_map(Spec) ->
    #{name => ensure_binary(Name),
      type => ensure_binary(maps:get(<<"type">>, Spec, <<>>)),
      description => ensure_binary(maps:get(<<"description">>, Spec, <<>>)),
      required => maps:is_key(ensure_binary(Name), RequiredSet)};
tool_parameter_from_term(Name, _Spec, RequiredSet) ->
    #{name => ensure_binary(Name),
      type => <<>>,
      description => <<>>,
      required => maps:is_key(ensure_binary(Name), RequiredSet)}.

tool_parameters_to_binary_json(undefined) ->
    undefined;
tool_parameters_to_binary_json(ToolParameters) ->
    json:encode(tool_parameters_to_term(ToolParameters)).

tool_parameters_to_term(#{type := Type} = Params) ->
    Properties = maps:get(properties, Params, []),
    {PropsMap, RequiredList} =
        lists:foldl(fun parameter_to_term/2, {#{}, []}, Properties),
    Base = #{<<"type">> => Type, <<"properties">> => PropsMap},
    case RequiredList of
        [] -> Base;
        _ -> Base#{<<"required">> => lists:reverse(RequiredList)}
    end;
tool_parameters_to_term(_) ->
    #{<<"type">> => <<"object">>, <<"properties">> => #{}}.

parameter_to_term(Param, {PropsMap, RequiredAcc}) ->
    Name = ensure_binary(maps:get(name, Param, <<>>)),
    PropSpec = #{
        <<"type">> => ensure_binary(maps:get(type, Param, <<>>)),
        <<"description">> => ensure_binary(maps:get(description, Param, <<>>))
    },
    RequiredAcc1 =
        case maps:get(required, Param, false) of
            true -> [Name | RequiredAcc];
            false -> RequiredAcc
        end,
    {PropsMap#{Name => PropSpec}, RequiredAcc1}.

json_value_to_term(#{string_value := V}) ->
    V;
json_value_to_term(#{number_value := V}) when is_float(V) ->
    normalize_number_term(V);
json_value_to_term(#{number_value := V}) ->
    V;
json_value_to_term(#{bool_value := V}) ->
    V;
json_value_to_term(#{null_value := true}) ->
    null;
json_value_to_term(#{object_value := #{fields := Fields}}) ->
    maps:from_list([{maps:get(key, Field, <<>>), json_value_to_term(maps:get(value, Field, #{null_value => true}))}
                    || Field <- Fields]);
json_value_to_term(#{array_value := #{items := Items}}) ->
    [json_value_to_term(Item) || Item <- Items];
json_value_to_term(_) ->
    null.

is_string_list([]) ->
    true;
is_string_list([H | T]) when is_integer(H), H >= 0, H =< 255 ->
    is_string_list(T);
is_string_list(_) ->
    false.

normalize_number_term(V) when is_float(V) ->
    case trunc(V) of
        I when I =:= V -> I;
        _ -> V
    end;
normalize_number_term(V) ->
    V.

ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
ensure_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
