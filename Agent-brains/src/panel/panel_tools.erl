-module(panel_tools).

-export([default_tool_descs/0, fetch_tool_descs/0]).

-define(LIST_TOOLS_TIMEOUT, 5000).

%% 静态兜底（Eion-tools 不可达时使用）。
default_tool_descs() ->
    [get_weather_desc(), memory_store_desc(), memory_search_desc(), memory_import_desc()].

%% 从 Eion-tools 动态拉取工具注册表；失败时回退 default_tool_descs/0。
fetch_tool_descs() ->
    try bridge_manager:list_tools(?LIST_TOOLS_TIMEOUT) of
        {ok, Tools} when is_list(Tools), Tools =/= [] ->
            [normalize_desc(T) || T <- Tools];
        _ ->
            default_tool_descs()
    catch _:_ ->
        default_tool_descs()
    end.

normalize_desc(T) when is_map(T) ->
    #{name => maps:get(name, T, <<>>),
      description => maps:get(description, T, <<>>),
      parameters_json => maps:get(parameters_json, T, <<>>)}.

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
