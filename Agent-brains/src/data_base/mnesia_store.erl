-module(mnesia_store).

%%====================================================================
%% Mnesia_Store —— ETS 快照的中期磁盘存储 (Disk-backed Snapshot/Restore)
%%====================================================================
%%
%% 职责:
%%   把任意 ETS 表的全部内容 (ets:tab2list/1) 序列化到 mnesia 磁盘表,
%%   供下一次启动时把 ETS 从磁盘快照恢复 (中期存储层)。
%%
%% 适用场景:
%%   - state_store 持有的会话快照/历史, 不希望进程崩溃就丢
%%   - cache 持有的配置项, 跨重启保留
%%
%% 不适用场景 (按需另选方案):
%%   - 高频写表: 每次写都触发 snapshot 性能太差, 应走 write-through 或定时器
%%   - 跨节点共享: 本实现单节点 disc_copies, 不做多节点复制
%%
%% 设计要点:
%%   - 单表 ets_snapshot: 主键 = ETS 表名 (atom), 值 = 该表全量 [{Key, Value}, ...]
%%   - snapshot/1 是"全量替换": 调用前先删旧记录, 再写新记录 (单事务内)
%%   - restore/1 是"全量加载": 调用前 ETS 表必须已存在 (named_table),
%%     restore 不重建表, 只把记录 ets:insert 回去
%%
%% 用法:
%%   ok = mnesia_store:init_store(),        %% 进程启动时一次性初始化
%%   ok = mnesia_store:snapshot(ets_tab),   %% dump ETS 到磁盘
%%   ok = mnesia_store:restore(ets_tab).    %% 把磁盘快照加载回 ETS
%%====================================================================

-export([init_store/0, snapshot/1, restore/1]).

-include("log.hrl").

-define(SNAPSHOT_TABLE, ets_snapshot).

%%--------------------------------------------------------------------
%% 初始化 mnesia schema 与快照表 (幂等, 多次调用安全)
%%--------------------------------------------------------------------
init_store() ->
    Dir = application:get_env(hermes_brains, mnesia_dir, "data/mnesia"),
    ok = filelib:ensure_dir(Dir ++ "/"),
    ok = application:set_env(mnesia, dir, Dir),
    Node = node(),
    %% 创建磁盘 schema (若已存在则忽略)
    case mnesia:create_schema([Node]) of
        ok ->
            ?log("mnesia schema created at ~s", [Dir]);
        {error, {_, {already_exists, _}}} ->
            ?log_trace("mnesia schema already exists at ~s", [Dir]);
        {error, Reason1} ->
            ?log_error("mnesia create_schema failed: ~p", [Reason1]),
            error({mnesia_schema_failed, Reason1})
    end,
    %% 启动 mnesia 应用
    case application:ensure_started(mnesia) of
        ok -> ok;
        {error, {already_started, mnesia}} -> ok;
        {error, Reason2} ->
            ?log_error("mnesia start failed: ~p", [Reason2]),
            error({mnesia_start_failed, Reason2})
    end,
    %% 创建 ets_snapshot 表 (disc_copies = 落盘)
    case mnesia:create_table(?SNAPSHOT_TABLE, [
        {attributes, [table_name, data]},
        {disc_copies, [Node]}
    ]) of
        {atomic, ok} ->
            ?log("mnesia snapshot table created (disc_copies)"),
            ok;
        {aborted, {already_exists, _}} ->
            ?log_trace("mnesia snapshot table already exists"),
            ok;
        {aborted, Reason3} ->
            ?log_error("mnesia create_table failed: ~p", [Reason3]),
            error({mnesia_create_table_failed, Reason3})
    end.

%%--------------------------------------------------------------------
%% 把整张 ETS 表的内容快照到磁盘 (全量替换)
%%--------------------------------------------------------------------
-spec snapshot(atom()) -> ok | {error, term()}.
snapshot(EtsTab) when is_atom(EtsTab) ->
    Data = ets:tab2list(EtsTab),
    case mnesia:transaction(fun() ->
        mnesia:write_lock_table(?SNAPSHOT_TABLE),
        mnesia:delete({?SNAPSHOT_TABLE, EtsTab}),
        mnesia:write(?SNAPSHOT_TABLE, {?SNAPSHOT_TABLE, EtsTab, Data}, write)
    end) of
        {atomic, ok} ->
            ?log("snapshot taken, table=~p, entries=~p", [EtsTab, length(Data)]),
            ok;
        {aborted, Reason} ->
            ?log_error("snapshot failed, table=~p, reason=~p", [EtsTab, Reason]),
            {error, Reason}
    end.

%%--------------------------------------------------------------------
%% 从磁盘快照恢复 ETS 表 (调用前 ETS 表必须已存在)
%%--------------------------------------------------------------------
-spec restore(atom()) -> ok | {error, no_snapshot}.
restore(EtsTab) when is_atom(EtsTab) ->
    {atomic, Result} = mnesia:transaction(fun() ->
        mnesia:read(?SNAPSHOT_TABLE, EtsTab)
    end),
    case Result of
        [{?SNAPSHOT_TABLE, EtsTab, Data}] when is_list(Data) ->
            lists:foreach(fun(Entry) -> ets:insert(EtsTab, Entry) end, Data),
            ?log("restore ok, table=~p, entries=~p", [EtsTab, length(Data)]),
            ok;
        [] ->
            ?log_warning("restore: no snapshot for table=~p", [EtsTab]),
            {error, no_snapshot}
    end.
