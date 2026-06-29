-module(native_tools).

%%====================================================================
%% Native_Tools —— Erlang 原生工具执行器
%%
%% 绕过 Go bridge，直接在 Erlang 侧执行的工具。
%% 适用场景: 纯 Erlang 内部状态操作 (如分层记忆 CRUD)，
%%          无需外部进程/IO，延迟敏感，或需要事务一致性。
%%
%% 当前工具集 (EXEC-P2-002 记忆分层):
%%   memory_fact       - 写入 facts 层记忆
%%   memory_preference - 写入 preferences 层记忆
%%   memory_workspace  - 写入 workspace 层记忆
%%   memory_forget     - 删除指定记忆
%%   memory_list       - 列出当前会话的分层记忆
%%
%% 所有工具返回统一格式: #{result_json => binary(), error => binary()}
%%====================================================================

-export([list_native_capabilities/0,
         is_native_tool/1,
         execute/3]).

%%====================================================================
%% API
%%====================================================================

%% 返回所有 Erlang-native 工具的 capability 描述列表
-spec list_native_capabilities() -> [map()].
list_native_capabilities() ->
    [memory_fact_cap(),
     memory_preference_cap(),
     memory_workspace_cap(),
     memory_forget_cap(),
     memory_list_cap()].

%% 判断工具名是否为 Erlang-native 工具
-spec is_native_tool(binary()) -> boolean().
is_native_tool(Name) when is_binary(Name) ->
    lists:member(Name, [<<"memory_fact">>, <<"memory_preference">>,
                        <<"memory_workspace">>, <<"memory_forget">>,
                        <<"memory_list">>]);
is_native_tool(_) -> false.

%% 执行一个 native 工具
%% ToolCall = #{id, name, arguments} (arguments 为 JSON binary 或已解码 map)
%% SessionId = 当前会话 ID
%% 返回 {ok, RespMap} | {error, Reason}
%% RespMap = #{result_json => binary(), error => binary()}
-spec execute(map(), binary(), [map()]) -> {ok, map()} | {error, term()}.
execute(#{name := Name} = TC, SessionId, _AvailableTools) ->
    try
        Args = parse_args(maps:get(arguments, TC, <<>>)),
        Result = do_execute(Name, SessionId, Args),
        {ok, #{result_json => json_encode(Result), error => <<>>}}
    catch
        throw:{invalid_args, Reason} ->
            {ok, #{result_json => <<>>, error => iolist_to_binary([<<"invalid arguments: ">>, to_bin(Reason)])}};
        Class:Err:Stack ->
            lager:error("native_tool ~s crashed: ~p:~p~n~p", [Name, Class, Err, Stack]),
            {ok, #{result_json => <<>>, error => <<"internal error">>}}
    end.

%%====================================================================
%% 工具 Capability 定义
%%====================================================================

memory_fact_cap() ->
    #{name => <<"memory_fact">>,
      kind => <<"tool">>,
      source => <<"erlang-native">>,
      version => <<"v1">>,
      description => util:u("记录一条事实性记忆 (如项目信息、用户陈述的事实、环境配置等)。这些记忆会被自动注入后续对话上下文。"),
      parameters_json => util:u(
          "{\"type\":\"object\","
          "\"properties\":{"
          "\"content\":{\"type\":\"string\",\"description\":\"要记住的事实内容\"},"
          "\"key\":{\"type\":\"string\",\"description\":\"可选，记忆键名（用于去重和查找）\"},"
          "\"global\":{\"type\":\"boolean\",\"description\":\"是否为全局记忆（跨会话生效），默认 false\"}"
          "},"
          "\"required\":[\"content\"]"
          "}"),
      streaming => false,
      risk_level => <<"safe">>,
      cost_hint => <<"low">>,
      tags => [<<"tool">>, <<"memory">>, <<"native">>]}.

memory_preference_cap() ->
    #{name => <<"memory_preference">>,
      kind => <<"tool">>,
      source => <<"erlang-native">>,
      version => <<"v1">>,
      description => util:u("记录一条用户偏好 (如代码风格、沟通方式、技术选型偏好等)。这些记忆会被自动注入后续对话上下文。"),
      parameters_json => util:u(
          "{\"type\":\"object\","
          "\"properties\":{"
          "\"content\":{\"type\":\"string\",\"description\":\"偏好描述\"},"
          "\"key\":{\"type\":\"string\",\"description\":\"可选，记忆键名\"},"
          "\"global\":{\"type\":\"boolean\",\"description\":\"是否为全局偏好（跨会话生效），默认 false\"}"
          "},"
          "\"required\":[\"content\"]"
          "}"),
      streaming => false,
      risk_level => <<"safe">>,
      cost_hint => <<"low">>,
      tags => [<<"tool">>, <<"memory">>, <<"native">>]}.

memory_workspace_cap() ->
    #{name => <<"memory_workspace">>,
      kind => <<"tool">>,
      source => <<"erlang-native">>,
      version => <<"v1">>,
      description => util:u("记录当前工作区/项目上下文 (如技术栈、目录结构、当前任务状态等)。这些记忆仅在当前会话有效。"),
      parameters_json => util:u(
          "{\"type\":\"object\","
          "\"properties\":{"
          "\"content\":{\"type\":\"string\",\"description\":\"上下文内容\"},"
          "\"key\":{\"type\":\"string\",\"description\":\"可选，记忆键名\"}"
          "},"
          "\"required\":[\"content\"]"
          "}"),
      streaming => false,
      risk_level => <<"safe">>,
      cost_hint => <<"low">>,
      tags => [<<"tool">>, <<"memory">>, <<"native">>]}.

memory_forget_cap() ->
    #{name => <<"memory_forget">>,
      kind => <<"tool">>,
      source => <<"erlang-native">>,
      version => <<"v1">>,
      description => util:u("删除一条指定的分层记忆。"),
      parameters_json => util:u(
          "{\"type\":\"object\","
          "\"properties\":{"
          "\"tier\":{\"type\":\"string\",\"enum\":[\"facts\",\"preferences\",\"workspace\"],\"description\":\"记忆层\"},"
          "\"key\":{\"type\":\"string\",\"description\":\"记忆键名\"}"
          "},"
          "\"required\":[\"tier\",\"key\"]"
          "}"),
      streaming => false,
      risk_level => <<"review">>,
      cost_hint => <<"low">>,
      tags => [<<"tool">>, <<"memory">>, <<"native">>]}.

memory_list_cap() ->
    #{name => <<"memory_list">>,
      kind => <<"tool">>,
      source => <<"erlang-native">>,
      version => <<"v1">>,
      description => util:u("列出当前会话中已记录的所有分层记忆，包括 facts、preferences、workspace 三层。"),
      parameters_json => util:u(
          "{\"type\":\"object\","
          "\"properties\":{"
          "\"tier\":{\"type\":\"string\",\"enum\":[\"facts\",\"preferences\",\"workspace\"],\"description\":\"可选，只列出指定层\"}"
          "},"
          "\"required\":[]"
          "}"),
      streaming => false,
      risk_level => <<"safe">>,
      cost_hint => <<"low">>,
      tags => [<<"tool">>, <<"memory">>, <<"native">>]}.

%%====================================================================
%% 内部执行逻辑
%%====================================================================

do_execute(<<"memory_fact">>, SessionId, Args) ->
    Content = require_arg(<<"content">>, Args),
    Key = maps:get(<<"key">>, Args, hash_key(Content)),
    ScopeSession = case maps:get(<<"global">>, Args, false) of
                       true -> <<"global">>;
                       _ -> SessionId
                   end,
    ok = memory_tier:put(ScopeSession, facts, Key, Content),
    #{status => <<"ok">>, tier => <<"facts">>, key => Key, global => ScopeSession =:= <<"global">>};

do_execute(<<"memory_preference">>, SessionId, Args) ->
    Content = require_arg(<<"content">>, Args),
    Key = maps:get(<<"key">>, Args, hash_key(Content)),
    ScopeSession = case maps:get(<<"global">>, Args, false) of
                       true -> <<"global">>;
                       _ -> SessionId
                   end,
    ok = memory_tier:put(ScopeSession, preferences, Key, Content),
    #{status => <<"ok">>, tier => <<"preferences">>, key => Key, global => ScopeSession =:= <<"global">>};

do_execute(<<"memory_workspace">>, SessionId, Args) ->
    Content = require_arg(<<"content">>, Args),
    Key = maps:get(<<"key">>, Args, hash_key(Content)),
    ok = memory_tier:put(SessionId, workspace, Key, Content),
    #{status => <<"ok">>, tier => <<"workspace">>, key => Key, global => false};

do_execute(<<"memory_forget">>, SessionId, Args) ->
    TierBin = require_arg(<<"tier">>, Args),
    Key = require_arg(<<"key">>, Args),
    Tier = parse_tier(TierBin),
    ok = memory_tier:delete(SessionId, Tier, Key),
    #{status => <<"ok">>, tier => TierBin, key => Key, deleted => true};

do_execute(<<"memory_list">>, SessionId, Args) ->
    case maps:get(<<"tier">>, Args, undefined) of
        undefined ->
            All = memory_tier:get_all(SessionId),
            format_all_layers(All);
        TierBin ->
            Tier = parse_tier(TierBin),
            Entries = memory_tier:get_tier(SessionId, Tier),
            #{tier => TierBin, entries => [format_entry(E) || E <- Entries]}
    end;

do_execute(Name, _SessionId, _Args) ->
    throw({invalid_args, iolist_to_binary([<<"unknown native tool: ">>, Name])}).

%%====================================================================
%% 辅助函数
%%====================================================================

parse_args(Args) when is_map(Args) ->
    Args;
parse_args(Args) when is_binary(Args) ->
    case byte_size(Args) of
        0 -> #{};
        _ ->
            try json:decode(Args)
            catch _:_ -> #{}
            end
    end;
parse_args(Args) when is_list(Args) ->
    case io_lib:char_list(Args) of
        true -> parse_args(iolist_to_binary(Args));
        false -> #{}
    end;
parse_args(_) ->
    #{}.

require_arg(Key, Args) ->
    case maps:get(Key, Args, undefined) of
        undefined -> throw({invalid_args, iolist_to_binary([<<"missing required argument: ">>, Key])});
        V -> to_bin(V)
    end.

parse_tier(<<"facts">>) -> facts;
parse_tier(<<"preferences">>) -> preferences;
parse_tier(<<"workspace">>) -> workspace;
parse_tier(T) -> throw({invalid_args, iolist_to_binary([<<"invalid tier: ">>, T])}).

format_all_layers(All) when is_map(All) ->
    #{facts => format_entries(maps:get(facts, All, [])),
      preferences => format_entries(maps:get(preferences, All, [])),
      workspace => format_entries(maps:get(workspace, All, []))};
format_all_layers(_) ->
    #{facts => [], preferences => [], workspace => []}.

format_entries(Entries) when is_list(Entries) ->
    [format_entry(E) || E <- Entries];
format_entries(_) ->
    [].

format_entry(#{key := K, content := C} = E) ->
    #{key => K,
      content => C,
      ts => maps:get(ts, E, 0),
      source => maps:get(source, E, <<>>)};
format_entry(#{<<"key">> := K, <<"content">> := C} = E) ->
    #{key => K,
      content => C,
      ts => maps:get(<<"ts">>, E, 0),
      source => maps:get(<<"source">>, E, <<>>)};
format_entry(_) ->
    #{}.

hash_key(Content) ->
    integer_to_binary(erlang:phash2(Content, 16#FFFFFFFF), 16).

json_encode(Term) ->
    try json:encode(Term)
    catch _:_ -> <<"{}">>
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) ->
    try list_to_binary(L)
    catch _:_ -> iolist_to_binary(io_lib:format("~p", [L]))
    end;
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(_) -> <<>>.
