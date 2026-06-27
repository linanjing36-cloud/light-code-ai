-module(go_exec).

%% Phase B: Erlang bridge_manager 经 panel 连接让 Wails Go 进程内执行 LLM/工具。

-export([enabled/0, call_llm/3, call_tool/5, call_tool_sync/2, list_tools/1, list_capabilities/1]).

-define(LLM_TIMEOUT, 60000).
-define(TOOL_TIMEOUT, 15000).

enabled() ->
    case application:get_env(hermes_brains, exec_via_panel) of
        {ok, true} -> true;
        {ok, <<"true">>} -> true;
        _ ->
            case os:getenv("HERMES_EXEC_VIA_PANEL") of
                "1" -> true;
                "true" -> true;
                _ -> false
            end
    end.

call_llm(FsmPid, Ref, Req) ->
    spawn(fun() -> do_call_llm(FsmPid, Ref, Req) end),
    Ref.

do_call_llm(FsmPid, Ref, Req) ->
    BizReq = bridge_manager:inject_llm_creds(Req),
    Payload = pb_codec:encode_req(BizReq),
    case panel_server:exec_agent(Payload, ?LLM_TIMEOUT) of
        {ok, RespBins} ->
            forward_llm(FsmPid, Ref, RespBins);
        {error, Reason} ->
            lager:warning("go_exec call_llm failed: ~p", [Reason]),
            gen_statem:cast(FsmPid, {bridge_disconnect})
    end.

forward_llm(FsmPid, Ref, RespBins) ->
    lists:foreach(fun(Bin) ->
        Resp = pb_codec:decode_resp(Bin),
        case maps:get(kind, Resp, unknown) of
            llm_chunk ->
                gen_statem:cast(FsmPid, {llm_chunk, Ref, Resp});
            llm_infer ->
                gen_statem:cast(FsmPid, {llm_response, Ref, Resp});
            Other ->
                lager:warning("go_exec unexpected llm resp kind: ~p", [Other])
        end
    end, RespBins).

call_tool(FsmPid, Ref, Id, Name, Args) ->
    spawn(fun() -> do_call_tool(FsmPid, Id, Name, Args) end),
    Ref.

do_call_tool(FsmPid, Id, Name, Args) ->
    BizReq = #{kind => tool_exec,
               req_id => Id,
               tool_name => Name,
               arguments_json => Args},
    Payload = pb_codec:encode_req(BizReq),
    case panel_server:exec_agent(Payload, ?TOOL_TIMEOUT) of
        {ok, [Bin | _]} ->
            gen_statem:cast(FsmPid, {tool_result, Id, pb_codec:decode_resp(Bin)});
        {ok, []} ->
            gen_statem:cast(FsmPid, {tool_result, Id,
                                     #{kind => tool_exec, error => <<"empty response">>}});
        {error, Reason} ->
            lager:warning("go_exec call_tool ~s failed: ~p", [Name, Reason]),
            gen_statem:cast(FsmPid, {bridge_disconnect})
    end.

call_tool_sync(#{id := Id, name := Name, arguments := Args}, TimeoutMs) ->
    BizReq = #{kind => tool_exec,
               req_id => Id,
               tool_name => Name,
               arguments_json => Args},
    Payload = pb_codec:encode_req(BizReq),
    case panel_server:exec_agent(Payload, TimeoutMs) of
        {ok, [Bin | _]} ->
            {ok, pb_codec:decode_resp(Bin)};
        {ok, []} ->
            {error, empty_response};
        {error, Reason} ->
            {error, Reason}
    end.

list_tools(TimeoutMs) ->
    Payload = pb_codec:encode_req(#{kind => tool_list}),
    case panel_server:exec_agent(Payload, TimeoutMs) of
        {ok, [Bin | _]} ->
            Resp = pb_codec:decode_resp(Bin),
            case maps:get(error, Resp, <<>>) of
                Err when Err =/= <<>> ->
                    {error, Err};
                _ ->
                    {ok, maps:get(tools, Resp, [])}
            end;
        {ok, []} ->
            {error, empty_response};
        {error, Reason} ->
            {error, Reason}
    end.

list_capabilities(TimeoutMs) ->
    Payload = pb_codec:encode_req(#{kind => capability_list}),
    case panel_server:exec_agent(Payload, TimeoutMs) of
        {ok, [Bin | _]} ->
            Resp = pb_codec:decode_resp(Bin),
            case maps:get(error, Resp, <<>>) of
                Err when Err =/= <<>> ->
                    {error, Err};
                _ ->
                    {ok, maps:get(capabilities, Resp, [])}
            end;
        {ok, []} ->
            {error, empty_response};
        {error, Reason} ->
            {error, Reason}
    end.
