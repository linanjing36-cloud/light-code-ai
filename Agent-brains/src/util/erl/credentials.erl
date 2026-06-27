-module(credentials).

-export([load_optional/0]).

-include("log.hrl").

%% 从 api-key.json 注入 api_key / default_model 到 application env。
%% 文件缺失时不阻塞启动 (Wails 探活 / 无 LLM 场景仍可连 panel_server)。
load_optional() ->
    case resolve_path() of
        {ok, Path} ->
            case file:read_file(Path) of
                {ok, Body} ->
                    M = decode_json(Body),
                    Key = maps:get(<<"api_key">>, M, <<>>),
                    Model = maps:get(<<"model">>, M, <<"deepseek-v4-pro">>),
                    application:set_env(hermes_brains, api_key, Key),
                    application:set_env(hermes_brains, default_model, Model),
                    ?log("credentials loaded from ~s (key prefix ~s...)",
                         [Path, util:safe_prefix(Key)]),
                    ok;
                {error, Reason} ->
                    ?log_warning("credentials read failed ~s: ~p", [Path, Reason]),
                    ok
            end;
        not_found ->
            ?log("credentials: no api-key.json found, LLM calls need manual env", []),
            ok
    end.

resolve_path() ->
    case os:getenv("API_KEY_FILE") of
        false -> try_default_paths();
        "" -> try_default_paths();
        P -> {ok, P}
    end.

try_default_paths() ->
    Paths = ["api-key.json", "../api-key.json", "../../api-key.json"],
    case lists:dropwhile(fun(P) -> not file_exists(P) end, Paths) of
        [P | _] -> {ok, P};
        [] -> not_found
    end.

file_exists(P) ->
    case file:read_file_info(P) of
        {ok, _} -> true;
        _ -> false
    end.

decode_json(Bin) ->
    case code:which(json) of
        non_existing -> util:extract_kv(Bin);
        _ -> json:decode(Bin)
    end.
