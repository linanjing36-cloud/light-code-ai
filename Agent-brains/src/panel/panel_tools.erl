-module(panel_tools).

-export([default_tool_descs/0, fetch_tool_descs/0,
         default_capability_descs/0, fetch_capability_descs/0]).

-define(LIST_TOOLS_TIMEOUT, 1500).

%% 静态兜底（Eion-tools 不可达时使用）。
default_tool_descs() ->
    [get_weather_desc(), memory_store_desc(), memory_search_desc(), memory_import_desc()].

default_capability_descs() ->
    [tool_desc_to_capability_desc(T, <<"builtin">>) || T <- default_tool_descs()].

%% 从 Eion-tools 动态拉取工具注册表；失败时回退 default_tool_descs/0。
fetch_tool_descs() ->
    try bridge_manager:list_tools(?LIST_TOOLS_TIMEOUT) of
        {ok, Tools} when is_list(Tools), Tools =/= [] ->
            [normalize_desc(T) || T <- Tools, not is_internal_tool(T)];
        _ ->
            default_tool_descs()
    catch _:_ ->
        default_tool_descs()
    end.

fetch_capability_descs() ->
    try bridge_manager:list_capabilities(?LIST_TOOLS_TIMEOUT) of
        {ok, Caps} when is_list(Caps), Caps =/= [] ->
            [normalize_capability_desc(C) || C <- Caps, not is_internal_capability(C)];
        _ ->
            default_capability_descs()
    catch _:_ ->
        default_capability_descs()
    end.

is_internal_tool(T) when is_map(T) ->
    maps:get(name, T, <<>>) =:= <<"memory_purge_session">>;
is_internal_tool(_) -> false.

is_internal_capability(C) when is_map(C) ->
    maps:get(name, C, <<>>) =:= <<"memory_purge_session">>;
is_internal_capability(_) -> false.

normalize_desc(T) when is_map(T) ->
    #{name => maps:get(name, T, <<>>),
      description => maps:get(description, T, <<>>),
      parameters_json => maps:get(parameters_json, T, <<>>)}.

normalize_capability_desc(C) when is_map(C) ->
    #{name => maps:get(name, C, <<>>),
      kind => non_empty(maps:get(kind, C, <<>>), <<"tool">>),
      source => non_empty(maps:get(source, C, <<>>), <<"builtin">>),
      version => non_empty(maps:get(version, C, <<>>), <<"v1">>),
      description => maps:get(description, C, <<>>),
      parameters_json => maps:get(input_schema_json, C, <<>>),
      streaming => maps:get(streaming, C, false),
      risk_level => non_empty(maps:get(risk_level, C, <<>>), <<"safe">>),
      cost_hint => non_empty(maps:get(cost_hint, C, <<>>), <<"low">>),
      tags => maps:get(tags, C, [])}.

tool_desc_to_capability_desc(T, Source) ->
    Name = maps:get(name, T, <<>>),
    #{name => Name,
      kind => capability_kind(Name),
      source => capability_source(Name, Source),
      version => <<"v1">>,
      description => maps:get(description, T, <<>>),
      parameters_json => maps:get(parameters_json, T, <<>>),
      streaming => false,
      risk_level => default_risk_level(Name),
      cost_hint => default_cost_hint(Name),
      tags => default_tags(Name)}.

default_risk_level(<<"memory_import">>) ->
    <<"review">>;
default_risk_level(<<"memory_store">>) ->
    <<"review">>;
default_risk_level(_Name) ->
    <<"safe">>.

capability_kind(<<"repo_map">>) ->
    <<"plugin">>;
capability_kind(<<"code_search">>) ->
    <<"plugin">>;
capability_kind(<<"github_repo_overview">>) ->
    <<"plugin">>;
capability_kind(<<"github_diff_summary">>) ->
    <<"plugin">>;
capability_kind(_) ->
    <<"tool">>.

capability_source(<<"repo_map">>, _Default) ->
    <<"local">>;
capability_source(<<"code_search">>, _Default) ->
    <<"local">>;
capability_source(<<"github_repo_overview">>, _Default) ->
    <<"local">>;
capability_source(<<"github_diff_summary">>, _Default) ->
    <<"local">>;
capability_source(_, Default) ->
    Default.

default_cost_hint(Name) ->
    case Name of
        <<"memory_import">> -> <<"medium">>;
        <<"repo_map">> -> <<"medium">>;
        <<"github_diff_summary">> -> <<"medium">>;
        _ -> <<"low">>
    end.

default_tags(<<"get_weather">>) ->
    [<<"tool">>, <<"builtin">>, <<"weather">>];
default_tags(<<"memory_store">>) ->
    [<<"tool">>, <<"memory">>];
default_tags(<<"memory_search">>) ->
    [<<"tool">>, <<"memory">>, <<"search">>];
default_tags(<<"memory_import">>) ->
    [<<"tool">>, <<"memory">>, <<"import">>];
default_tags(<<"repo_map">>) ->
    [<<"plugin">>, <<"workspace">>, <<"token-saving">>];
default_tags(<<"code_search">>) ->
    [<<"plugin">>, <<"code">>, <<"search">>, <<"token-saving">>];
default_tags(<<"github_repo_overview">>) ->
    [<<"plugin">>, <<"github">>, <<"git">>, <<"token-saving">>];
default_tags(<<"github_diff_summary">>) ->
    [<<"plugin">>, <<"github">>, <<"git">>, <<"diff">>, <<"token-saving">>];
default_tags(_) ->
    [<<"tool">>].

non_empty(<<>>, Default) ->
    Default;
non_empty(Value, _Default) ->
    Value.

get_weather_desc() ->
    #{name => <<"get_weather">>,
      description => util:u("获取指定城市的当前天气。仅支持中国主要城市。"),
      parameters_json => util:u(
          "{\"type\":\"object\","
          "\"properties\":{"
          "\"city\":{\"type\":\"string\",\"description\":\"城市名，例如 北京/上海/深圳\"}"
          "},"
          "\"required\":[\"city\"]"
          "}")}.

memory_store_desc() ->
    #{name => <<"memory_store">>,
      description => util:u(
          "将一段文本存入长期记忆（向量库），供后续 memory_search 检索。"
          "适用于用户明确要求记住的信息、会话中的重要事实。"),
      parameters_json => util:u(
          "{\"type\":\"object\","
          "\"properties\":{"
          "\"session_id\":{\"type\":\"string\",\"description\":\"会话 ID\"},"
          "\"text\":{\"type\":\"string\",\"description\":\"要记住的文本\"},"
          "\"doc_id\":{\"type\":\"string\",\"description\":\"可选文档 ID\"},"
          "\"metadata_json\":{\"type\":\"string\",\"description\":\"可选元数据 JSON\"}"
          "},"
          "\"required\":[\"session_id\",\"text\"]"
          "}")}.

memory_search_desc() ->
    #{name => <<"memory_search">>,
      description => util:u(
          "从长期记忆（向量库）检索与查询语义相关的历史片段。"
          "可限定 session_id 只搜当前会话。"),
      parameters_json => util:u(
          "{\"type\":\"object\","
          "\"properties\":{"
          "\"query\":{\"type\":\"string\",\"description\":\"检索查询\"},"
          "\"session_id\":{\"type\":\"string\",\"description\":\"可选，限定会话\"},"
          "\"top_k\":{\"type\":\"integer\",\"description\":\"返回条数，默认 5\"}"
          "},"
          "\"required\":[\"query\"]"
          "}")}.

memory_import_desc() ->
    #{name => <<"memory_import">>,
      description => util:u(
          "将长文档分块导入长期记忆（向量库），供 memory_search 检索。"
          "适用于外部知识、说明文档等批量入库。"),
      parameters_json => util:u(
          "{\"type\":\"object\","
          "\"properties\":{"
          "\"session_id\":{\"type\":\"string\",\"description\":\"会话 ID\"},"
          "\"document_text\":{\"type\":\"string\",\"description\":\"完整文档文本\"},"
          "\"chunk_size\":{\"type\":\"integer\",\"description\":\"分块字符数，默认 400\"},"
          "\"source\":{\"type\":\"string\",\"description\":\"可选来源标识\"}"
          "},"
          "\"required\":[\"session_id\",\"document_text\"]"
          "}")}.
