-module(agent_demo).

%%====================================================================
%% Agent_Demo —— 端到端 ReAct 链路验证 (Phase 1.4 收尾)
%%====================================================================
%%
%% 用途:
%%   在 rebar3 shell 中执行 agent_demo:run(). 即可拉起一次完整的
%%   Erlang(FSM) → bridge_manager(Port) → Eion-tools(Go) → DeepSeek
%%   → 响应回链 → ReAct 循环 → 工具调用 → 最终答案 的端到端验证。
%%
%% 前置条件:
%%   1. /tmp/eion-tools-server 已构建 (cd Eion-tools && go build -o /tmp/eion-tools-server ./cmd/server)
%%   2. ./api-key.json 存在 (本仓库 .gitignore 已忽略, 仅本地调试用)
%%   3. DeepSeek API 可达
%%
%% 注意:
%%   本模块仅用于联调验证, 不属于生产代码路径。
%%   关键是: 一次跑通 = Phase 1.4 通信基座全部打通。
%%====================================================================

-export([run/0, run/1]).

-define(DEFAULT_SESSION, <<"demo-sess-1">>).

%%%===================================================================
%%% 对外接口
%%%===================================================================

%% 默认查询: 询问北京天气 (会触发 get_weather 工具调用)
run() ->
    run(util:u("北京今天天气怎么样？")).

%% 自定义用户 query 的端到端演示
%% 流程: 加载 app -> 注入凭证与 server 路径 -> 启动 app -> 起 FSM -> 触发 ReAct -> 等待结束 -> 打印历史
run(Query) when is_binary(Query) ->
    %% 1. 先 load hermes_brains 应用, 让 .app.src 中的 env 默认值生效
    %%    (set_env 在 load 之前调用会被 load 覆盖)
    ok = application:load(hermes_brains),
    %% 2. 注入凭证: api_key 来自 api-key.json (本地调试, .gitignore 已忽略)
    ok = load_credentials(),
    %% 3. 指定 Eion-tools server 可执行文件 (绝对路径, 不依赖 PATH)
    application:set_env(hermes_brains, eion_tools_bin, "/tmp/eion-tools-server"),
    %% 4. 启动 hermes_brains 应用 (启动顶层监督者 + state_store + bridge_manager + agent_sup)
    ok = ensure_started(),
    %% 5. 打印环境概览
    print_env(),
    %% 6. 启动一个 Agent_FSM: 带 get_weather 工具, 用户 query 作为第一条消息
    {ok, FsmPid} = start_fsm(Query),
    io:format("~n=== Agent_FSM 已启动, PID=~p, 等待 ReAct 循环结束 ===~n", [FsmPid]),
    %% 7. 触发 ReAct 主循环 (cast start, idle -> thinking)
    agent_fsm:start(FsmPid, #{}),
    %% 8. 等待 FSM 回到 idle (循环结束), 最多等 90s
    ok = wait_idle(FsmPid, 90000),
    %% 9. 拉取会话历史并打印
    print_history(?DEFAULT_SESSION),
    ok.

%%%===================================================================
%%% 内部函数
%%%===================================================================

%% 启动 hermes_brains 应用 (幂等)
ensure_started() ->
    case application:ensure_all_started(hermes_brains) of
        {ok, _Started} ->
            io:format("[demo] hermes_brains 应用已启动~n"),
            ok;
        {error, {already_started, hermes_brains}} ->
            io:format("[demo] hermes_brains 应用已在运行~n"),
            ok;
        {error, Reason} ->
            io:format("[demo] 启动失败: ~p~n", [Reason]),
            {error, Reason}
    end.

%% 从 api-key.json 读取 api_key 和 model, 注入到 application env
%% 文件路径优先取 env API_KEY_FILE, 否则尝试:
%%   1. 当前工作目录 ./api-key.json
%%   2. 项目根 ../api-key.json (在 Agent-brains/ 下运行 rebar3 shell 时)
load_credentials() ->
    Path = case os:getenv("API_KEY_FILE") of
        false ->
            case file:read_file("api-key.json") of
                {ok, _} -> "api-key.json";
                _ -> "../api-key.json"
            end;
        P -> P
    end,
    {ok, Body} = file:read_file(Path),
    io:format("[demo] 从 ~s 加载凭证~n", [Path]),
    Key = maps:get(<<"api_key">>, jsx_decode_safe(Body), <<>>),
    Model = maps:get(<<"model">>, jsx_decode_safe(Body), <<"deepseek-v4-pro">>),
    application:set_env(hermes_brains, api_key, Key),
    application:set_env(hermes_brains, default_model, Model),
    io:format("[demo] api_key 已注入 (前 8 位: ~s...), default_model=~s~n",
              [util:safe_prefix(Key), Model]),
    ok.

%% 兼容: 没有 jsx 依赖时, 用 erlang 自带的 json 模块 (OTP 26+)
jsx_decode_safe(Bin) ->
    case code:which(json) of
        non_existing ->
            %% 老版本 OTP 没有 json 模块, 退化用正则提取 (够 demo 用)
            util:extract_kv(Bin);
        _ ->
            json:decode(Bin)
    end.

%% (extract_kv / extract_string_field / safe_prefix / u 已迁出至 util.erl)

%% 打印当前 application env (用于调试)
print_env() ->
    ServerBin = application:get_env(hermes_brains, eion_tools_bin, "eion-tools-server"),
    ApiBase = application:get_env(hermes_brains, api_base, <<>>),
    Model = application:get_env(hermes_brains, default_model, <<>>),
    io:format("[demo] env: eion_tools_bin=~s, api_base=~s, model=~s~n",
              [ServerBin, ApiBase, Model]).

%% 启动一个 FSM, 携带 get_weather 工具 + 用户 query 作为初始历史
start_fsm(Query) ->
    Tools = [get_weather_tool()],
    InitialHistory = [#{role => <<"user">>, content => Query}],
    Args = [{session_id, ?DEFAULT_SESSION},
            {model, application:get_env(hermes_brains, default_model, <<"deepseek-v4-pro">>)},
            {tools, Tools},
            {history, InitialHistory}],
    case agent_sup:start_agent(Args) of
        {ok, Pid} ->
            %% 把初始用户消息写入 state_store 历史 (供 wait_idle 轮询读取)
            [state_store:append_history(?DEFAULT_SESSION, M) || M <- InitialHistory],
            {ok, Pid};
        {error, _} = E ->
            E
    end.

%% get_weather 工具描述 (与 Eion-tools server.go GetWeatherHandler 对齐)
get_weather_tool() ->
    %% 注意: 含中文的字面量必须走 util:u/1 (string list -> unicode:characters_to_binary/2),
    %%       直接写 <<"...中文...">> 二进制字面量在编译期会被破坏 (非有效 UTF-8)。
    #{
        name => <<"get_weather">>,
        description => util:u("获取指定城市的当前天气。仅支持中国主要城市。"),
        parameters_json => util:u(
            "{\"type\":\"object\","
            "\"properties\":{"
            "\"city\":{\"type\":\"string\",\"description\":\"城市名，例如 北京/上海/深圳\"}"
            "},"
            "\"required\":[\"city\"]"
            "}")
    }.

%% 等待 FSM 回到 idle (轮询 state_store 快照, loop_count 不再增长 + history 末尾出现 assistant 无 tool_calls)
wait_idle(FsmPid, TimeoutMs) ->
    Deadline = erlang:system_time(millisecond) + TimeoutMs,
    wait_idle_loop(FsmPid, Deadline, 0).

wait_idle_loop(FsmPid, Deadline, _Iter) ->
    case erlang:is_process_alive(FsmPid) of
        false ->
            io:format("[demo] FSM 进程已退出~n"),
            ok;
        true ->
            Now = erlang:system_time(millisecond),
            if Now >= Deadline ->
                   io:format("[demo] 等待 FSM 超时, 强制结束观察~n"),
                   ok;
               true ->
                   timer:sleep(1000),
                   %% 检查最后一条历史是否是 assistant 且无 tool_calls (意味着 LLM 给出最终答案)
                   case state_store:get_history(?DEFAULT_SESSION) of
                       {ok, []} ->
                           wait_idle_loop(FsmPid, Deadline, _Iter + 1);
                       {ok, History} ->
                           Last = lists:last(History),
                           case is_final_answer(Last) of
                               true ->
                                   io:format("[demo] FSM 已回 idle (最终答案就绪)~n"),
                                   ok;
                               false ->
                                   wait_idle_loop(FsmPid, Deadline, _Iter + 1)
                           end
                   end
            end
    end.

%% 打印会话历史 (展示完整的 ReAct 思考链路)
print_history(SessionId) ->
    case state_store:get_history(SessionId) of
        {ok, []} ->
            io:format("~n=== (无历史记录) ===~n");
        {ok, History} ->
            io:format("~n=== ReAct 会话历史 (会话 ~s) ===~n", [SessionId]),
            lists:foldl(fun(M, I) ->
                io:format("~n--- [#~p] ~s ---~n",
                          [I, maps:get(role, M, <<>>)]),
                case maps:get(content, M, <<>>) of
                    <<>> -> ok;
                    Content -> io:format("content: ~s~n", [Content])
                end,
                case maps:get(tool_calls, M, []) of
                    [] -> ok;
                    ToolCalls ->
                        io:format("tool_calls:~n", []),
                        lists:foreach(fun(TC) ->
                            io:format("  - id=~s name=~s args=~s~n",
                                      [maps:get(id, TC, <<>>),
                                       maps:get(name, TC, <<>>),
                                       maps:get(arguments, TC, <<>>)])
                        end, ToolCalls)
                end,
                case maps:get(tool_call_id, M, <<>>) of
                    <<>> -> ok;
                    TCId -> io:format("tool_call_id: ~s~n", [TCId])
                end,
                I + 1
            end, 1, History),
            io:format("~n=== 历史结束 ===~n")
    end.

%% 判断一条历史消息是否构成最终答案
%%   role=assistant 且 tool_calls 为空 (或不存在)
%%   (LLM 在最终轮不再要求调用工具, 视为已给出最终答复)
is_final_answer(#{role := <<"assistant">>} = Msg) ->
    case maps:get(tool_calls, Msg, []) of
        [] -> true;
        _ -> false
    end;
is_final_answer(_) ->
    false.

%% (u/1 已迁出至 util.erl)
