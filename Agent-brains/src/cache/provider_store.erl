-module(provider_store).
-behaviour(gen_server).

%%====================================================================
%% Provider_Store —— Provider 配置与权限中心 (EXEC-P2-003)
%%
%% 职责:
%%   1. 多 provider 配置管理 (模型名 -> provider 映射, api_base, api_key)
%%   2. API key 安全存储 (Mnesia disc_copies, 不进入 FSM 状态)
%%   3. 工具级权限策略 (risk_level -> 执行策略: allow/approve/deny)
%%   4. 会话级凭证注入 (按 session 覆盖默认 provider)
%%
%% 存储:
%%   - providers 表: {ProviderId, Name, ApiBase, ApiKey, Models, Enabled}
%%   - model_routes 表: {ModelName, ProviderId}  (模型路由)
%%   - risk_policies 表: {risk_level, action}     (风险策略)
%%   - session_providers 表: {SessionId, ProviderId} (会话覆盖)
%%====================================================================

-export([start_link/0,
         list_providers/0,
         get_provider/1,
         upsert_provider/1,
         delete_provider/1,
         set_default_provider/1,
         get_default_provider/0,
         resolve_provider/1,
         resolve_creds/1,
         list_models/0,
         route_model/2,
         set_risk_policy/2,
         get_risk_policy/1,
         set_session_provider/2,
         clear_session_provider/1,
         inject_llm_creds/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("log.hrl").

-define(SERVER, ?MODULE).
-define(PROVIDER_TAB, provider_configs).
-define(ROUTE_TAB, model_routes).
-define(RISK_TAB, risk_policies).
-define(SESSION_TAB, session_providers).

-record(state, {}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% 列出所有已启用的 provider（api_key 掩码）
-spec list_providers() -> [map()].
list_providers() ->
    gen_server:call(?SERVER, list_providers, 5000).

%% 获取单个 provider 配置（api_key 掩码）
-spec get_provider(binary()) -> {ok, map()} | {error, not_found}.
get_provider(ProviderId) ->
    gen_server:call(?SERVER, {get_provider, ProviderId}, 5000).

%% 新增或更新 provider 配置
%% Provider = #{id, name, api_base, api_key, models => [binary()], enabled => boolean()}
-spec upsert_provider(map()) -> ok | {error, term()}.
upsert_provider(Provider) ->
    gen_server:call(?SERVER, {upsert_provider, Provider}, 5000).

%% 删除 provider
-spec delete_provider(binary()) -> ok | {error, term()}.
delete_provider(ProviderId) ->
    gen_server:call(?SERVER, {delete_provider, ProviderId}, 5000).

%% 设置默认 provider
-spec set_default_provider(binary()) -> ok | {error, term()}.
set_default_provider(ProviderId) ->
    gen_server:call(?SERVER, {set_default, ProviderId}, 5000).

%% 获取默认 provider ID
-spec get_default_provider() -> {ok, binary()} | {error, not_set}.
get_default_provider() ->
    case mnesia:dirty_read(?PROVIDER_TAB, <<"_default">>) of
        [{?PROVIDER_TAB, <<"_default">>, Pid}] -> {ok, Pid};
        _ -> {error, not_set}
    end.

%% 解析模型对应的 provider（含会话覆盖）
-spec resolve_provider(binary() | undefined) -> {ok, map()} | {error, term()}.
resolve_provider(Model) when is_binary(Model) ->
    gen_server:call(?SERVER, {resolve_provider, Model}, 5000);
resolve_provider(_) ->
    case get_default_provider() of
        {ok, DefaultId} -> get_provider_raw(DefaultId);
        Err -> Err
    end.

%% 获取凭证（含 api_key 明文，仅供 bridge_manager 内部注入使用）
%% 返回 {ok, #{api_base, api_key, provider_id}} | {error, _}
-spec resolve_creds(binary() | undefined) -> {ok, map()} | {error, term()}.
resolve_creds(Model) ->
    gen_server:call(?SERVER, {resolve_creds, Model}, 5000).

%% 列出所有可用模型
-spec list_models() -> [map()].
list_models() ->
    gen_server:call(?SERVER, list_models, 5000).

%% 为指定模型路由到指定 provider
-spec route_model(binary(), binary()) -> ok | {error, term()}.
route_model(ModelName, ProviderId) ->
    gen_server:call(?SERVER, {route_model, ModelName, ProviderId}, 5000).

%% 设置风险策略: risk_level (safe/review/dangerous) -> action (allow/approve/deny)
-spec set_risk_policy(binary(), binary()) -> ok | {error, term()}.
set_risk_policy(RiskLevel, Action) ->
    gen_server:call(?SERVER, {set_risk_policy, RiskLevel, Action}, 5000).

%% 获取风险策略
-spec get_risk_policy(binary()) -> {ok, binary()} | {error, term()}.
get_risk_policy(RiskLevel) ->
    case mnesia:dirty_read(?RISK_TAB, RiskLevel) of
        [{?RISK_TAB, _, Action}] -> {ok, Action};
        _ -> {ok, default_risk_action(RiskLevel)}
    end.

%% 设置会话级 provider 覆盖
-spec set_session_provider(binary(), binary()) -> ok | {error, term()}.
set_session_provider(SessionId, ProviderId) ->
    gen_server:call(?SERVER, {set_session_provider, SessionId, ProviderId}, 5000).

%% 清除会话 provider
-spec clear_session_provider(binary()) -> ok.
clear_session_provider(SessionId) ->
    gen_server:cast(?SERVER, {clear_session, SessionId}).

%% 注入 LLM 凭证到请求（替代 bridge_manager 中的硬编码逻辑）
%% Req 包含 model -> 解析对应 provider 的 api_base/api_key
-spec inject_llm_creds(map(), binary() | undefined) -> map().
inject_llm_creds(Req, SessionId) ->
    Model = maps:get(model, Req, <<>>),
    case resolve_creds_for_model(Model, SessionId) of
        {ok, #{api_base := Base, api_key := Key}} ->
            Req#{kind => llm_infer, api_base => Base, api_key => Key};
        _ ->
            %% 降级到旧的 app env 读取（兼容模式）
            DefaultBase = application:get_env(hermes_brains, api_base, <<>>),
            DefaultKey = application:get_env(hermes_brains, api_key, <<>>),
            Req#{kind => llm_infer, api_base => DefaultBase, api_key => DefaultKey}
    end.

%%====================================================================
%% gen_server 回调
%%====================================================================

init([]) ->
    case create_tables() of
        ok ->
            seed_default_policies(),
            seed_from_env(),
            ?log("provider_store started"),
            {ok, #state{}};
        {error, Reason} ->
            ?log_error("provider_store init failed: ~p", [Reason]),
            {stop, Reason}
    end.

handle_call(list_providers, _From, State) ->
    Providers = do_list_providers(),
    {reply, Providers, State};

handle_call({get_provider, Id}, _From, State) ->
    Result = case do_get_provider(Id) of
        {ok, P} -> {ok, mask_key(P)};
        Err -> Err
    end,
    {reply, Result, State};

handle_call({upsert_provider, Provider}, _From, State) ->
    Result = do_upsert_provider(Provider),
    {reply, Result, State};

handle_call({delete_provider, Id}, _From, State) ->
    Result = do_delete_provider(Id),
    {reply, Result, State};

handle_call({set_default, Id}, _From, State) ->
    Result = do_set_default(Id),
    {reply, Result, State};

handle_call({resolve_provider, Model}, _From, State) ->
    Result = do_resolve_provider(Model, undefined),
    {reply, Result, State};

handle_call({resolve_creds, Model}, _From, State) ->
    Result = do_resolve_creds(Model, undefined),
    {reply, Result, State};

handle_call(list_models, _From, State) ->
    Models = do_list_models(),
    {reply, Models, State};

handle_call({route_model, Model, ProviderId}, _From, State) ->
    Result = do_route_model(Model, ProviderId),
    {reply, Result, State};

handle_call({set_risk_policy, Level, Action}, _From, State) ->
    Result = do_set_risk_policy(Level, Action),
    {reply, Result, State};

handle_call({set_session_provider, SessionId, ProviderId}, _From, State) ->
    Result = do_set_session_provider(SessionId, ProviderId),
    {reply, Result, State};

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({clear_session, SessionId}, State) ->
    do_clear_session(SessionId),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% 内部: Mnesia 存储
%%====================================================================

create_tables() ->
    Node = node(),
    Tabs = [
        {?PROVIDER_TAB, set, [provider_id, name, api_base, api_key, models, enabled, is_default]},
        {?ROUTE_TAB, set, [model_name, provider_id]},
        {?RISK_TAB, set, [risk_level, action]},
        {?SESSION_TAB, set, [session_id, provider_id]}
    ],
    lists:foreach(fun({Tab, Type, Attrs}) ->
        case mnesia:create_table(Tab, [
            {attributes, Attrs},
            {disc_copies, [Node]},
            {type, Type}
        ]) of
            {atomic, ok} -> ?log("provider table created: ~p", [Tab]);
            {aborted, {already_exists, _}} -> ok;
            {aborted, Reason} -> ?log_warning("provider table ~p create: ~p", [Tab, Reason])
        end
    end, Tabs),
    ok.

seed_default_policies() ->
    Defaults = [
        {<<"safe">>, <<"allow">>},
        {<<"review">>, <<"approve">>},
        {<<"dangerous">>, <<"deny">>}
    ],
    lists:foreach(fun({Level, Action}) ->
        case mnesia:dirty_read(?RISK_TAB, Level) of
            [] ->
                mnesia:dirty_write(?RISK_TAB, {?RISK_TAB, Level, Action});
            _ -> ok
        end
    end, Defaults).

seed_from_env() ->
    DefaultBase = application:get_env(hermes_brains, api_base, <<>>),
    DefaultKey = application:get_env(hermes_brains, api_key, <<>>),
    DefaultModel = application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>),
    case {DefaultBase, DefaultKey} of
        {<<>>, <<>>} -> ok;
        _ ->
            EnvProvider = #{
                id => <<"env-default">>,
                name => <<"环境配置">>,
                api_base => DefaultBase,
                api_key => DefaultKey,
                models => [DefaultModel],
                enabled => true
            },
            case do_upsert_provider(EnvProvider) of
                ok -> do_set_default(<<"env-default">>);
                _ -> ok
            end
    end.

%%====================================================================
%% 内部: CRUD
%%====================================================================

do_list_providers() ->
    case mnesia:transaction(fun() ->
        mnesia:match_object(?PROVIDER_TAB, {?PROVIDER_TAB, '_', '_', '_', '_', '_', '_', '_'}, read)
    end) of
        {atomic, Rows} ->
            [mask_key(record_to_map(R)) || R <- Rows,
                element(2, R) =/= <<"_default">>,
                element(7, R) =/= false];
        _ -> []
    end.

do_get_provider(Id) ->
    case mnesia:dirty_read(?PROVIDER_TAB, Id) of
        [Rec] -> {ok, record_to_map(Rec)};
        _ -> {error, not_found}
    end.

get_provider_raw(Id) ->
    case mnesia:dirty_read(?PROVIDER_TAB, Id) of
        [Rec] -> {ok, record_to_map_full(Rec)};
        _ -> {error, not_found}
    end.

do_upsert_provider(#{id := Id} = P) ->
    Name = maps:get(name, P, Id),
    ApiBase = maps:get(api_base, P, <<>>),
    ApiKey = maps:get(api_key, P, <<>>),
    Models = maps:get(models, P, []),
    Enabled = maps:get(enabled, P, true),
    IsDefault = maps:get(is_default, P, false),
    case mnesia:transaction(fun() ->
        mnesia:write(?PROVIDER_TAB,
                     {?PROVIDER_TAB, Id, to_bin(Name), to_bin(ApiBase), to_bin(ApiKey),
                      [to_bin(M) || M <- Models], Enabled, IsDefault},
                     write),
        lists:foreach(fun(Model) ->
            mnesia:write(?ROUTE_TAB,
                         {?ROUTE_TAB, to_bin(Model), Id},
                         write)
        end, Models)
    end) of
        {atomic, ok} ->
            ?log("provider upserted: ~s", [Id]),
            ok;
        {aborted, Reason} ->
            {error, Reason}
    end;
do_upsert_provider(_) ->
    {error, invalid_provider}.

do_delete_provider(Id) ->
    case Id of
        <<"env-default">> -> {error, cannot_delete_env};
        _ ->
            case mnesia:transaction(fun() ->
                mnesia:delete(?PROVIDER_TAB, Id, write),
                Routes = mnesia:match_object(?ROUTE_TAB, {?ROUTE_TAB, '_', Id}, write),
                lists:foreach(fun(R) -> mnesia:delete_object(?ROUTE_TAB, R, write) end, Routes)
            end) of
                {atomic, ok} -> ok;
                {aborted, Reason} -> {error, Reason}
            end
    end.

do_set_default(Id) ->
    case mnesia:dirty_read(?PROVIDER_TAB, Id) of
        [] -> {error, provider_not_found};
        _ ->
            case mnesia:transaction(fun() ->
                %% 清除旧默认
                OldDefaults = mnesia:match_object(?PROVIDER_TAB,
                    {?PROVIDER_TAB, '_', '_', '_', '_', '_', '_', true}, write),
                lists:foreach(fun(R) ->
                    mnesia:write(?PROVIDER_TAB, setelement(8, R, false), write)
                end, OldDefaults),
                %% 记录默认指针
                mnesia:write(?PROVIDER_TAB, {?PROVIDER_TAB, <<"_default">>, Id}, write),
                %% 设置新默认
                [Rec] = mnesia:read(?PROVIDER_TAB, Id),
                mnesia:write(?PROVIDER_TAB, setelement(8, Rec, true), write)
            end) of
                {atomic, ok} -> ok;
                {aborted, Reason} -> {error, Reason}
            end
    end.

do_resolve_provider(Model, SessionId) ->
    ProviderId = resolve_provider_id(Model, SessionId),
    case get_provider_raw(ProviderId) of
        {ok, P} -> {ok, mask_key(P)};
        Err -> Err
    end.

do_resolve_creds(Model, SessionId) ->
    ProviderId = resolve_provider_id(Model, SessionId),
    get_provider_raw(ProviderId).

resolve_provider_id(Model, SessionId) ->
    SessionProvider = case SessionId of
        undefined -> undefined;
        _ ->
            case mnesia:dirty_read(?SESSION_TAB, SessionId) of
                [{?SESSION_TAB, _, SessPid}] -> SessPid;
                _ -> undefined
            end
    end,
    case SessionProvider of
        undefined ->
            case mnesia:dirty_read(?ROUTE_TAB, Model) of
                [{?ROUTE_TAB, _, RoutePid}] -> RoutePid;
                _ ->
                    case get_default_provider() of
                        {ok, DefaultId} -> DefaultId;
                        _ -> <<"env-default">>
                    end
            end;
        SessPid0 -> SessPid0
    end.

resolve_creds_for_model(Model, SessionId) ->
    ProviderId = resolve_provider_id(Model, SessionId),
    get_provider_raw(ProviderId).

do_list_models() ->
    case mnesia:transaction(fun() ->
        mnesia:match_object(?ROUTE_TAB, {?ROUTE_TAB, '_', '_'}, read)
    end) of
        {atomic, Routes} ->
            [begin
                ProviderName = case mnesia:read(?PROVIDER_TAB, Pid) of
                    [{?PROVIDER_TAB, _, Name, _, _, _, Enabled, _}] when Enabled =/= false ->
                        Name;
                    _ -> <<"unknown">>
                end,
                #{model => Model, provider_id => Pid, provider_name => ProviderName}
             end || {?ROUTE_TAB, Model, Pid} <- Routes];
        _ -> []
    end.

do_route_model(Model, ProviderId) ->
    case mnesia:dirty_read(?PROVIDER_TAB, ProviderId) of
        [] -> {error, provider_not_found};
        _ ->
            case mnesia:transaction(fun() ->
                mnesia:write(?ROUTE_TAB, {?ROUTE_TAB, to_bin(Model), ProviderId}, write)
            end) of
                {atomic, ok} -> ok;
                {aborted, Reason} -> {error, Reason}
            end
    end.

do_set_risk_policy(Level, Action) ->
    ValidLevels = [<<"safe">>, <<"review">>, <<"dangerous">>],
    ValidActions = [<<"allow">>, <<"approve">>, <<"deny">>],
    case {lists:member(Level, ValidLevels), lists:member(Action, ValidActions)} of
        {true, true} ->
            mnesia:dirty_write(?RISK_TAB, {?RISK_TAB, Level, Action}),
            ?log("risk policy set: ~s -> ~s", [Level, Action]),
            ok;
        _ -> {error, invalid_policy}
    end.

do_set_session_provider(SessionId, ProviderId) ->
    case mnesia:dirty_read(?PROVIDER_TAB, ProviderId) of
        [] -> {error, provider_not_found};
        _ ->
            mnesia:dirty_write(?SESSION_TAB, {?SESSION_TAB, SessionId, ProviderId}),
            ok
    end.

do_clear_session(SessionId) ->
    mnesia:dirty_delete(?SESSION_TAB, SessionId),
    ok.

%%====================================================================
%% 内部: 辅助函数
%%====================================================================

record_to_map({?PROVIDER_TAB, Id, Name, ApiBase, _ApiKey, Models, Enabled, IsDefault}) ->
    #{id => Id,
      name => Name,
      api_base => ApiBase,
      models => Models,
      enabled => Enabled,
      is_default => IsDefault =:= true}.

record_to_map_full({?PROVIDER_TAB, Id, Name, ApiBase, ApiKey, Models, Enabled, IsDefault}) ->
    #{id => Id,
      name => Name,
      api_base => ApiBase,
      api_key => ApiKey,
      models => Models,
      enabled => Enabled,
      is_default => IsDefault =:= true}.

mask_key(P) when is_map(P) ->
    P#{api_key => mask_key_bin(maps:get(api_key, P, <<>>))};
mask_key(Rec) ->
    mask_key(record_to_map(Rec)).

mask_key_bin(<<>>) -> <<>>;
mask_key_bin(Key) when byte_size(Key) =< 8 -> <<"****">>;
mask_key_bin(Key) ->
    Prefix = binary:part(Key, 0, 4),
    <<Prefix/binary, "****">>.

default_risk_action(<<"safe">>) -> <<"allow">>;
default_risk_action(<<"review">>) -> <<"approve">>;
default_risk_action(<<"dangerous">>) -> <<"deny">>;
default_risk_action(_) -> <<"allow">>.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(_) -> <<>>.
