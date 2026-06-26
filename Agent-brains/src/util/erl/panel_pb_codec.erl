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
    %% 解码: binary -> 业务级 tagged tuple
    unpack_frame/1            %% (Bin) -> {request, Id, Method, ArgsMap}
                              %%       | {response, Id, ok, ResultBytes}
                              %%       | {response, Id, error, ErrMsg}
                              %%       | {stream, StreamId, StreamPayload}
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
    Inner = #{stream_id => StreamId,
              tool_event => #{tool_call_id => maps:get(tool_call_id, EvMap, <<>>),
                              name => maps:get(name, EvMap, <<>>),
                              arguments_json => maps:get(arguments_json, EvMap, <<>>),
                              result_json => maps:get(result_json, EvMap, <<>>),
                              error => maps:get(error, EvMap, <<>>),
                              finished => maps:get(finished, EvMap, false)}},
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
    if
        IsReq -> decode_request(maps:get(request, Frame));
        IsResp -> decode_response(maps:get(response, Frame));
        IsStream -> decode_stream(maps:get(stream, Frame));
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
                    {stream, StreamId, {tool_event,
                        #{tool_call_id => maps:get(tool_call_id, Ev, <<>>),
                          name => maps:get(name, Ev, <<>>),
                          arguments_json => maps:get(arguments_json, Ev, <<>>),
                          result_json => maps:get(result_json, Ev, <<>>),
                          error => maps:get(error, Ev, <<>>),
                          finished => maps:get(finished, Ev, false)}}};
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

%%%===================================================================
%%% 按 method 路由的 Args/Result 编解码
%%%===================================================================

%% ---- Args (request) ----
encode_args(<<"start_session">>, #{system_prompt := SP}) ->
    ?PANEL_PB:encode_msg(#{system_prompt => SP}, 'StartSessionArgs');
encode_args(<<"send">>, #{session_id := SessId, message := Msg}) ->
    ?PANEL_PB:encode_msg(#{session_id => SessId, message => Msg}, 'SendArgs');
encode_args(<<"approve">>, #{req_id := ReqId, allow := Allow}) ->
    ?PANEL_PB:encode_msg(#{req_id => ReqId, allow => Allow}, 'ApproveArgs');
encode_args(<<"brain_status">>, #{session_id := SessId}) ->
    ?PANEL_PB:encode_msg(#{session_id => SessId}, 'BrainStatusArgs');
encode_args(_NoArgsMethod, _ArgsMap) ->
    %% list_tools / stop 无参数, args_bytes 为空
    <<>>.

decode_args(<<"start_session">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'StartSessionArgs'),
    #{system_prompt => maps:get(system_prompt, M, <<>>)};
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
decode_args(_NoArgsMethod, _Bin) ->
    #{}.

%% ---- Result (response) ----
encode_result(<<"start_session">>, #{session_id := SessId}) ->
    ?PANEL_PB:encode_msg(#{session_id => SessId}, 'StartSessionResult');
encode_result(<<"send">>, #{stream_id := StreamId}) ->
    ?PANEL_PB:encode_msg(#{stream_id => StreamId}, 'SendResult');
encode_result(<<"list_tools">>, #{tools := Tools}) ->
    PbTools = [#{name => maps:get(name, T, <<>>),
                description => maps:get(description, T, <<>>),
                parameters_json => maps:get(parameters_json, T, <<>>)} || T <- Tools],
    ?PANEL_PB:encode_msg(#{tools => PbTools}, 'ListToolsResult');
encode_result(<<"approve">>, #{ok := Ok}) ->
    ?PANEL_PB:encode_msg(#{ok => Ok}, 'ApproveResult');
encode_result(<<"brain_status">>, M) ->
    PbM = #{state => maps:get(state, M, <<>>),
            loop_count => maps:get(loop_count, M, 0),
            max_loops => maps:get(max_loops, M, 0),
            history_len => maps:get(history_len, M, 0)},
    ?PANEL_PB:encode_msg(PbM, 'BrainStatusResult');
encode_result(<<"stop">>, #{ok := Ok}) ->
    ?PANEL_PB:encode_msg(#{ok => Ok}, 'StopResult');
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
    #{tools => [#{name => maps:get(name, T, <<>>),
                  description => maps:get(description, T, <<>>),
                  parameters_json => maps:get(parameters_json, T, <<>>)}
                 || T <- maps:get(tools, M, [])]};
decode_result(<<"approve">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'ApproveResult'),
    #{ok => maps:get(ok, M, false)};
decode_result(<<"brain_status">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'BrainStatusResult'),
    #{state => maps:get(state, M, <<>>),
      loop_count => maps:get(loop_count, M, 0),
      max_loops => maps:get(max_loops, M, 0),
      history_len => maps:get(history_len, M, 0)};
decode_result(<<"stop">>, Bin) ->
    M = ?PANEL_PB:decode_msg(Bin, 'StopResult'),
    #{ok => maps:get(ok, M, false)};
decode_result(_Method, _Bin) ->
    #{}.
