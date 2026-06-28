-module(capability_selector).

-export([select/2, dropped/2, normalize/1]).

-spec select([map()], map()) -> [map()].
select(Capabilities, Ctx) when is_list(Capabilities), is_map(Ctx) ->
    [normalize(Cap)
     || Cap <- unique_by_name(Capabilities),
        capability_policy:allow(normalize(Cap), Ctx)].

-spec dropped([map()], map()) -> [binary()].
dropped(Capabilities, Ctx) when is_list(Capabilities), is_map(Ctx) ->
    [maps:get(name, Cap1, <<>>)
     || Cap <- unique_by_name(Capabilities),
        begin
            Cap1 = normalize(Cap),
            not capability_policy:allow(Cap1, Ctx)
        end].

-spec normalize(map()) -> map().
normalize(Capability) when is_map(Capability) ->
    %% P0-005 第二阶段: high risk 能力保留在可见列表, 打 requires_approval 标记。
    %% agent_fsm acting 时按此标记决定是否走审批流程 (注册 approval_store + push_approval_required)。
    Risk = maps:get(risk_level, Capability, <<"safe">>),
    RequiresApproval = capability_policy:requires_approval(#{risk_level => Risk}),
    Capability#{
        name => maps:get(name, Capability, <<>>),
        kind => maps:get(kind, Capability, <<"tool">>),
        source => maps:get(source, Capability, <<"builtin">>),
        version => maps:get(version, Capability, <<"v1">>),
        description => maps:get(description, Capability, <<>>),
        parameters_json => parameters_json(Capability),
        streaming => maps:get(streaming, Capability, false),
        risk_level => Risk,
        requires_approval => RequiresApproval,
        cost_hint => maps:get(cost_hint, Capability, <<"low">>),
        tags => maps:get(tags, Capability, [])
    }.

unique_by_name(Capabilities) ->
    {_Seen, Result} =
        lists:foldl(
          fun(Cap, {Seen, Acc}) when is_map(Cap) ->
                  Name = maps:get(name, normalize(Cap), <<>>),
                  case Name =:= <<>> orelse maps:is_key(Name, Seen) of
                      true -> {Seen, Acc};
                      false -> {maps:put(Name, true, Seen), Acc ++ [Cap]}
                  end;
             (_, State) ->
                  State
          end, {#{}, []}, Capabilities),
    Result.

parameters_json(Capability) ->
    case maps:get(parameters_json, Capability, undefined) of
        undefined -> maps:get(input_schema_json, Capability, <<>>);
        Value -> Value
    end.
