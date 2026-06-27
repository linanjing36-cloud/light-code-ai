-module(util).

%%====================================================================
%% Util —— 通用工具函数 (全项目共享)
%%====================================================================
%%
%% 收拢自 agent_demo.erl / bridge_ping.erl 中重复的工具函数:
%%   u/1            —— UTF-8 字符串转 binary (源码字面量在 erl_opts{encoding,utf8}
%%                     下被读为 latin1, 需 unicode:characters_to_binary/2 显式转码)
%%   safe_prefix/1  —— 截取 api_key 前 8 字节用于安全打印 (避免在日志泄漏完整 key)
%%   extract_kv/1   —— 退化 JSON 解析 (无 jsx 依赖时从 api-key.json 提取字段)
%%   extract_string_field/2 —— 退化正则提取单个 JSON 字符串字段
%%====================================================================

-export([u/1, safe_prefix/1,
         extract_kv/1, extract_string_field/2,
         resolve_eion_tools_addr_file/0]).

%% UTF-8 字符串辅助: string list -> unicode:characters_to_binary/2
%% 含中文的字面量必须走本函数, 直接写 <<"...中文...">> 二进制字面量在编译期会被破坏。
-spec u(string() | binary()) -> binary().
u(Str) -> unicode:characters_to_binary(Str, utf8).

%% 安全打印 api_key 前缀 (避免在日志里泄漏完整 key)
-spec safe_prefix(binary()) -> binary() | string().
safe_prefix(Key) when byte_size(Key) >= 8 ->
    <<Pre:8/binary, _/binary>> = Key,
    Pre;
safe_prefix(_) -> "****".

%% 退化解析: 从 api-key.json 提取 api_key / model
%% (无 jsx 依赖时用正则提取, 够 demo 用; OTP 26+ 优先用 json 模块)
-spec extract_kv(binary()) -> #{binary() => binary()}.
extract_kv(Bin) ->
    ApiKey = extract_string_field(Bin, <<"api_key">>),
    Model = extract_string_field(Bin, <<"model">>),
    #{<<"api_key">> => ApiKey, <<"model">> => Model}.

%% 极简正则: "field": "value"
-spec extract_string_field(binary(), binary()) -> binary().
extract_string_field(Bin, Field) ->
    Pattern = <<$", Field/binary, $", "\\s*:\\s*\"([^\"]+)\"">>,
    {ok, RE} = re:compile(Pattern),
    case re:run(Bin, RE, [{capture, all_but_first, binary}]) of
        {match, [Val]} -> Val;
        nomatch -> <<>>
    end.

%% Eion-tools 地址文件解析 (联调脚本 / start-agent.bat 共用)
%% 优先级: 环境变量 EION_TOOLS_ADDR_FILE > app env (文件须存在) > ../bin/run/eion-tools.addr
-spec resolve_eion_tools_addr_file() -> string().
resolve_eion_tools_addr_file() ->
    case os:getenv("EION_TOOLS_ADDR_FILE") of
        F when F =/= false, F =/= "" ->
            F;
        _ ->
            AppFile = case application:get_env(hermes_brains, eion_tools_addr_file) of
                {ok, P} when is_list(P), P =/= "" -> P;
                _ -> "../bin/run/eion-tools.addr"
            end,
            case filelib:is_regular(AppFile) of
                true -> AppFile;
                false -> "../bin/run/eion-tools.addr"
            end
    end.
