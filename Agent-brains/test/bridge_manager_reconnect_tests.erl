-module(bridge_manager_reconnect_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% REG-010: 断连恢复回归测试 (自动化 eunit)
%%
%% 测试目标:
%%   1. bridge_manager 能建立 TCP 连接池 (pool_info 显示 connected=N)
%%   2. 单个 socket 断开后, bridge_manager 在 RECONNECT_DELAY (2000ms) 后自动重连
%%   3. 全部 socket 断开后, bridge_manager 调度全局重连
%%
%% 测试策略:
%%   - 启动 mock TCP 服务端 (gen_tcp:listen + acceptor 循环)
%%   - 用 app env eion_tools_addr 指定 mock 地址, eion_tools_pool_size=2
%%   - 直接 gen_server:start_link 启动 bridge_manager (不通过 application supervisor)
%%   - 通过 mock 服务端关闭 socket 模拟断连, 验证 bridge_manager 自动重连
%%
%% 注意: bridge_manager 是 {local, ?MODULE} 注册名, 测试中需确保无残留进程。
%%====================================================================

-define(RECONNECT_DELAY_MS, 2000).   %% 与 bridge_manager.hrl 一致
-define(RECONNECT_WAIT_MS, 3500).    %% RECONNECT_DELAY + 1500ms 余量
-define(POOL_WAIT_MS, 5000).         %% 等待连接池建立

%%====================================================================
%% 测试夹具
%%====================================================================

setup() ->
    %% 加载 application (不启动) 以便设置 env
    catch application:load(hermes_brains),
    %% 停止残留 bridge_manager 进程 (上轮 cleanup 失败时可能残留)
    catch gen_server:stop(bridge_manager),
    ok = application:set_env(hermes_brains, exec_via_panel, false),
    %% 启动 lager (bridge_manager 依赖)
    {ok, _} = application:ensure_all_started(lager),
    %% 启动 mock TCP 服务端
    {ok, ListenSock} = gen_tcp:listen(0, [binary, {packet, 4}, {active, true},
                                          {reuseaddr, true}, {backlog, 10}]),
    {ok, Port} = inet:port(ListenSock),
    Addr = "127.0.0.1:" ++ integer_to_list(Port),
    ok = application:set_env(hermes_brains, eion_tools_addr, Addr),
    ok = application:set_env(hermes_brains, eion_tools_pool_size, 2),
    MockPid = spawn(fun() -> mock_acceptor_loop(ListenSock, []) end),
    %% 启动 bridge_manager (独立 gen_server, 不通过 application supervisor)
    {ok, BridgePid} = gen_server:start({local, bridge_manager}, bridge_manager, [], []),
    ok = wait_connected(2, ?POOL_WAIT_MS),
    #{listen => ListenSock, mock => MockPid, addr => Addr, bridge => BridgePid, port => Port}.

cleanup(#{listen := ListenSock, mock := MockPid, bridge := BridgePid}) ->
    catch gen_server:stop(BridgePid),
    catch exit(MockPid, kill),
    catch gen_tcp:close(ListenSock),
    catch application:unset_env(hermes_brains, eion_tools_addr),
    catch application:unset_env(hermes_brains, eion_tools_pool_size),
    catch application:unset_env(hermes_brains, exec_via_panel),
    ok.

%%====================================================================
%% 测试用例
%%====================================================================

bridge_reconnect_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun pool_builds_correctly/1,
      fun reconnect_after_single_socket_close/1,
      fun survives_full_disconnect/1]}.

%% 用例 1: bridge_manager 能建立 N 个 TCP 连接
pool_builds_correctly(#{bridge := _BridgePid}) ->
    Info = bridge_manager:pool_info(),
    [
     ?_assertEqual(2, maps:get(pool_size, Info)),
     ?_assertEqual(2, maps:get(connected, Info)),
     ?_assertEqual(2, maps:get(idle, Info)),
     ?_assertEqual(0, maps:get(busy, Info)),
     ?_assertEqual(0, maps:get(queue_len, Info))
    ].

%% 用例 2: 关闭一个 mock 服务端 socket, 验证 bridge_manager 自动重连
reconnect_after_single_socket_close(#{mock := MockPid}) ->
    %% 初始 pool: connected=2
    InitialInfo = bridge_manager:pool_info(),
    ?assertEqual(2, maps:get(connected, InitialInfo)),
    %% 从 mock 服务端关闭一个 socket (模拟 Eion-tools 单连接断开)
    MockPid ! {close_one, self()},
    receive
        {closed, _ClosedSock} -> ok
    after 1000 ->
        throw(close_one_timeout)
    end,
    %% 立即检查: connected 应为 1 (尚未重连)
    timer:sleep(200),
    AfterCloseInfo = bridge_manager:pool_info(),
    ?assertEqual(1, maps:get(connected, AfterCloseInfo)),
    %% 等待 RECONNECT_DELAY + 余量, bridge_manager 应已自动重连
    timer:sleep(?RECONNECT_WAIT_MS),
    AfterReconnectInfo = bridge_manager:pool_info(),
    ?_assertEqual(2, maps:get(connected, AfterReconnectInfo)).

%% 用例 3: 全部 socket 断开后, bridge_manager 存活且调度全局重连
%% 验证: 即使服务端持续不可用, bridge_manager 进程不崩溃, pool_size 配置保留
survives_full_disconnect(#{mock := MockPid, bridge := BridgePid}) ->
    %% 关闭所有 mock 服务端 socket (listen 仍保留, 但不再 accept 新连接)
    MockPid ! {close_all, self()},
    receive
        all_closed -> ok
    after 1000 -> throw(close_all_timeout)
    end,
    %% 等待 bridge_manager 检测到所有 socket 断开
    timer:sleep(500),
    AfterDisconnectInfo = bridge_manager:pool_info(),
    ?assert(maps:get(connected, AfterDisconnectInfo) =< 2),
    %% 等待一个重连周期, bridge_manager 应存活且持续重试
    timer:sleep(?RECONNECT_WAIT_MS),
    ?assert(erlang:is_process_alive(BridgePid)),
    FinalInfo = bridge_manager:pool_info(),
    ?_assertEqual(2, maps:get(pool_size, FinalInfo)).

%%====================================================================
%% 辅助函数
%%====================================================================

%% mock TCP 服务端: 持续 accept 并跟踪所有 socket
mock_acceptor_loop(ListenSock, Socks) ->
    case gen_tcp:accept(ListenSock, 200) of
        {ok, Sock} ->
            mock_acceptor_loop(ListenSock, [Sock | Socks]);
        {error, timeout} ->
            receive
                {get_socks, From} ->
                    From ! {socks, Socks},
                    mock_acceptor_loop(ListenSock, Socks);
                {close_one, From} ->
                    case Socks of
                        [S | Rest] ->
                            gen_tcp:close(S),
                            From ! {closed, S},
                            mock_acceptor_loop(ListenSock, Rest);
                        [] ->
                            From ! no_socks,
                            mock_acceptor_loop(ListenSock, Socks)
                    end;
                {close_all, From} ->
                    [gen_tcp:close(S) || S <- Socks],
                    From ! all_closed,
                    mock_acceptor_loop(ListenSock, []);
                {stop, From} ->
                    [gen_tcp:close(S) || S <- Socks],
                    From ! stopped,
                    ok
            after 0 ->
                mock_acceptor_loop(ListenSock, Socks)
            end
    end.

%% 等待连接池建立 (connected 数达到 N)
wait_connected(N, Timeout) ->
    wait_connected(N, Timeout, erlang:system_time(millisecond)).

wait_connected(N, Timeout, Start) ->
    Info = bridge_manager:pool_info(),
    Connected = maps:get(connected, Info, 0),
    case Connected >= N of
        true -> ok;
        false ->
            case erlang:system_time(millisecond) - Start > Timeout of
                true -> erlang:error({timeout_waiting_for_pool, N, Info});
                false -> timer:sleep(100), wait_connected(N, Timeout, Start)
            end
    end.
