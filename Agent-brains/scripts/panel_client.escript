#!/usr/bin/env escript
%% -*- erlang -*-
-mode(compile).

main([]) ->
    Root = filename:join([filename:dirname(escript:script_name()), "..", ".."]),
    Ebin = filename:join([Root, "bin", "erl_bin", "hermes_brains", "ebin"]),
    true = code:add_patha(Ebin),
    AddrFile = filename:join([Root, "bin", "run", "panel.addr"]),
    {ok, AddrBin} = file:read_file(AddrFile),
    Addr = string:trim(binary_to_list(AddrBin)),
    {Host, Port} = parse_addr(Addr),
    io:format("connect ~s:~p~n", [Host, Port]),
    {ok, Sock} = gen_tcp:connect(Host, Port, [binary, {packet, 4}, {active, false}]),
    Frame = panel_pb_codec:pack_request(1, <<"start_session">>, #{system_prompt => <<"hi">>}),
    ok = gen_tcp:send(Sock, Frame),
    io:format("sent protobuf ~p bytes~n", [byte_size(Frame)]),
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Resp} ->
            io:format("OK ~p~n", [panel_pb_codec:unpack_frame(Resp)]),
            halt(0);
        {error, Reason} ->
            io:format("FAIL recv ~p~n", [Reason]),
            halt(1)
    end.

parse_addr(AddrStr) ->
    case string:split(AddrStr, ":", all) of
        [Host, PortStr] -> {Host, list_to_integer(PortStr)};
        _ -> error(bad_addr)
    end.
