-module(capability_policy).

-export([allow/2, filter/2]).

%% 运行时能力策略:
%% - 默认屏蔽高风险 capability，审批链路落地前不暴露给模型
%% - 代码/仓库类 capability 仅在代码相关上下文中暴露
%% - memory 写入/导入类 capability 仅在明确记忆相关上下文中暴露

-spec filter([map()], map()) -> [map()].
filter(Capabilities, Ctx) when is_list(Capabilities), is_map(Ctx) ->
    [Cap || Cap <- Capabilities, allow(Cap, Ctx)].

-spec allow(map(), map()) -> boolean().
allow(Capability, Ctx) when is_map(Capability), is_map(Ctx) ->
    case is_high_risk(Capability) of
        true ->
            false;
        false ->
            Intent = classify_intent(Ctx),
            case bucket(Capability) of
                code_intel ->
                    maps:get(code, Intent, false);
                memory_write ->
                    maps:get(memory, Intent, false);
                memory_read ->
                    maps:get(memory, Intent, false);
                generic ->
                    true
            end
    end;
allow(_, _) ->
    false.

classify_intent(Ctx) ->
    Text = lower_bin(context_text(Ctx)),
    #{
        code => has_any(Text, code_keywords()),
        memory => has_any(Text, memory_keywords())
    }.

context_text(Ctx) ->
    History = maps:get(history, Ctx, []),
    SessionPrompt = maps:get(session_prompt, Ctx, <<>>),
    UserTexts = recent_user_contents(History, 6),
    iolist_to_binary(lists:join(<<"\n">>, UserTexts ++ [SessionPrompt])).

recent_user_contents(History, Limit) ->
    UserMsgs = [maps:get(content, Msg, <<>>)
                || Msg <- History,
                   is_map(Msg),
                   maps:get(role, Msg, <<>>) =:= <<"user">>],
    Tail = tail(UserMsgs, Limit),
    [T || T <- Tail, is_binary(T), T =/= <<>>].

tail(List, Limit) when is_list(List), is_integer(Limit), Limit > 0 ->
    Len = length(List),
    case Len =< Limit of
        true -> List;
        false -> lists:nthtail(Len - Limit, List)
    end;
tail(List, _Limit) ->
    List.

bucket(Capability) ->
    Name = maps:get(name, Capability, <<>>),
    Tags = maps:get(tags, Capability, []),
    case {Name, has_any_tag(Tags, [<<"workspace">>, <<"code">>, <<"search">>, <<"github">>, <<"git">>])} of
        {<<"repo_map">>, _} -> code_intel;
        {<<"code_search">>, _} -> code_intel;
        {<<"github_repo_overview">>, _} -> code_intel;
        {<<"github_diff_summary">>, _} -> code_intel;
        {<<"memory_store">>, _} -> memory_write;
        {<<"memory_import">>, _} -> memory_write;
        {<<"memory_search">>, _} -> memory_read;
        {_, true} -> code_intel;
        _ -> generic
    end.

is_high_risk(Capability) ->
    Risk = lower_bin(maps:get(risk_level, Capability, <<"safe">>)),
    lists:member(Risk, [<<"high">>, <<"critical">>, <<"dangerous">>]).

has_any_tag(Tags, Expected) ->
    LowerTags = [lower_bin(Tag) || Tag <- Tags, is_binary(Tag)],
    lists:any(fun(Tag) -> lists:member(Tag, LowerTags) end, Expected).

has_any(Text, Keywords) ->
    lists:any(fun(Keyword) -> binary:match(Text, Keyword) =/= nomatch end, Keywords).

code_keywords() ->
    [<<"code">>, <<"repo">>, <<"repository">>, <<"git">>, <<"github">>, <<"diff">>,
     <<"commit">>, <<"pr">>, <<"file">>, <<"files">>, <<"module">>, <<"symbol">>,
     <<"search">>, <<"workspace">>, <<"bug">>, <<"debug">>, <<"review">>,
     util:u("代码"), util:u("仓库"), util:u("文件"), util:u("模块"), util:u("函数"),
     util:u("实现"), util:u("搜索"), util:u("检索"), util:u("调试"), util:u("报错"),
     util:u("提交"), util:u("差异"), util:u("评审")].

memory_keywords() ->
    [<<"memory">>, <<"remember">>, <<"recall">>, <<"knowledge">>, <<"document">>,
     <<"documents">>, <<"import">>, <<"retrieve">>,
     util:u("记住"), util:u("记忆"), util:u("回忆"), util:u("召回"),
     util:u("知识库"), util:u("文档"), util:u("导入"), util:u("检索")].

lower_bin(Bin) when is_binary(Bin) ->
    unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(Bin)));
lower_bin(Other) ->
    Other.
