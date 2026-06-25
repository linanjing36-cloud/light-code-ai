#!/usr/bin/env bash
# start.sh - 启动 Hermes Agent 大脑 (Erlang/OTP)
#
# 用法:
#   ./bin/start.sh                          # 默认开发模式 (MODE=dev)
#   MODE=prod ./bin/start.sh                # 发布模式
#   MNESIA_DIR=/custom/path ./bin/start.sh  # 覆盖 mnesia 目录 (优先级最高)
#
# 模式切换 (MODE=dev|prod):
#   dev  (默认): WORK_DIR=Agent-brains/, mnesia 在 config/mnesia/, log 在 log/
#   prod        : WORK_DIR=bin/erl_bin/, mnesia 在 data/mnesia/, log 在 log/
#                 (sys.config 用 bin/erl_bin/config/sys.config, 由 make agent 拷贝)
#
# 退出:
#   Ctrl+C         : erl +B i 直接 halt (不优雅, 但快)
#   ./bin/stop.sh  : rpc init:stop() 触发 app terminate (推荐, 优雅)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_DIR="$ROOT_DIR/Agent-brains"
ERL_BIN_DIR="$ROOT_DIR/bin/erl_bin"
EION_BIN_DIR="$ROOT_DIR/bin/eion_bin"

# === 模式切换: dev (默认) | prod ===
# dev : 开发模式, 工作目录在 Agent-brains/, mnesia 在 config/mnesia/
# prod: 发布模式, 工作目录在 bin/erl_bin/, mnesia 在 data/mnesia/, 用打包好的 sys.config
MODE="${MODE:-dev}"
case "$MODE" in
    dev)
        WORK_DIR="$AGENT_DIR"
        DEFAULT_MNESIA_DIR="$AGENT_DIR/config/mnesia"
        DEFAULT_LOG_DIR="$AGENT_DIR/log"
        DEFAULT_EION_TOOLS_BIN="$ROOT_DIR/Eion-tools/cmd/server/eion-tools-server"
        DEFAULT_SYS_CONFIG="$AGENT_DIR/config/sys.config"
        ;;
    prod)
        WORK_DIR="$ERL_BIN_DIR"
        DEFAULT_MNESIA_DIR="$ERL_BIN_DIR/data/mnesia"
        DEFAULT_LOG_DIR="$ERL_BIN_DIR/log"
        DEFAULT_EION_TOOLS_BIN="$EION_BIN_DIR/eion-tools-server"
        DEFAULT_SYS_CONFIG="$ERL_BIN_DIR/config/sys.config"
        # 发布模式 sys.config 不存在则 fallback 到源码
        if [ ! -f "$DEFAULT_SYS_CONFIG" ]; then
            DEFAULT_SYS_CONFIG="$AGENT_DIR/config/sys.config"
        fi
        ;;
    *)
        echo "ERROR: MODE 必须是 dev 或 prod, 当前: $MODE" >&2
        exit 1
        ;;
esac

# 工作目录: cd 到 WORK_DIR (sys.config 里 log_root="log" 是相对路径, 这样 log 落对地方)
cd "$WORK_DIR"

# 检查编译产物
if [ ! -d "$ERL_BIN_DIR" ]; then
    echo "ERROR: 编译产物不存在, 请先执行: make agent" >&2
    exit 1
fi

# 环境变量覆盖 (优先级最高) > MODE 默认值
MNESIA_DIR="${MNESIA_DIR:-$DEFAULT_MNESIA_DIR}"
LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
EION_TOOLS_BIN="${EION_TOOLS_BIN:-$DEFAULT_EION_TOOLS_BIN}"
SYS_CONFIG="${SYS_CONFIG:-$DEFAULT_SYS_CONFIG}"
SNAPSHOT_INTERVAL_MS="${SNAPSHOT_INTERVAL_MS:-60000}"

PID_FILE="$LOG_DIR/hermes_brains.pid"

# 节点名 + cookie (rpc 远程停止用)
NODE_NAME="${NODE_NAME:-hermes_brains}"
NODE_COOKIE="${NODE_COOKIE:-hermes_brains}"

# 已有实例在跑则拒绝启动
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "ERROR: Agent 大脑已在运行 (pid=$OLD_PID), 请先执行: ./bin/stop.sh" >&2
        exit 1
    fi
    rm -f "$PID_FILE"
fi

# ERL_LIBS: 让 erl 自动从 bin/erl_bin/* 加载所有 OTP app
export ERL_LIBS="$ERL_BIN_DIR"

# 确保 log/mnesia 目录存在
mkdir -p "$LOG_DIR" "$MNESIA_DIR"

# hermes_brains 应用环境注入
HERMES_ENV="-hermes_brains eion_tools_bin \"$EION_TOOLS_BIN\""
HERMES_ENV="$HERMES_ENV -hermes_brains mnesia_dir \"$MNESIA_DIR\""
HERMES_ENV="$HERMES_ENV -hermes_brains snapshot_interval_ms $SNAPSHOT_INTERVAL_MS"

# 启动表达式: 设置 list 类型的 env, 然后启动应用
EVAL_CMD='application:set_env(hermes_brains, snapshot_tables, [hermes_brains_state]), {ok, _} = application:ensure_all_started(hermes_brains)'

# === Erlang VM 优化启动参数 (针对 Agent 大脑场景) ===
# +K true          内核 poll, 减少 fd 系统调用 (bridge_manager 端口 IO 多)
# +A 128           异步线程池大小, 用于 file/port 等阻塞调用 (Go port 通信必备)
# +P 1048576       最大进程数 (1M, 每个 agent 一个 FSM, 长期运行不限制)
# +sbwt none       调度器忙等待阈值 (none=不忙等, 低延迟优先)
# +sbwtdcpu none   调度器 CPU 忙等待阈值
# +sbwtdio none    调度器 IO 忙等待阈值
# +zdbbl 8192      分布输出缓冲区 KB
# +B i             Ctrl+C 直接 interrupt (erl halt, 不进 BREAK 菜单)
ERL_ARGS="+K true +A 128 +P 1048576 +sbwt none +sbwtdcpu none +sbwtdio none +zdbbl 8192"
KERNEL_ARGS="-kernel net_ticktime 60"

# 启动 erl (后台 + wait 模式, bash 保留下来处理 trap)
erl \
    -noinput +B i \
    -sname "$NODE_NAME" \
    -setcookie "$NODE_COOKIE" \
    $ERL_ARGS \
    $KERNEL_ARGS \
    -env ERL_CRASH_DUMP "$LOG_DIR/erl_crash.dump" \
    -config "$SYS_CONFIG" \
    $HERMES_ENV \
    -eval "$EVAL_CMD" &
ERL_PID=$!

# 写 PID 文件
echo "$ERL_PID" > "$PID_FILE"

# 退出时清理 PID 文件 (不主动 kill erl, 让 erl +B i 自己处理 SIGINT)
cleanup() {
    rm -f "$PID_FILE"
}
trap cleanup EXIT INT TERM

echo "==> 启动 Hermes Agent 大脑 (mode=$MODE)"
echo "    ERL_LIBS       = $ERL_LIBS"
echo "    node           = $NODE_NAME@$(hostname -s)"
echo "    EION_TOOLS_BIN = $EION_TOOLS_BIN"
echo "    MNESIA_DIR     = $MNESIA_DIR"
echo "    LOG_DIR        = $LOG_DIR"
echo "    SYS_CONFIG     = $SYS_CONFIG"
echo "    SNAPSHOT_INT   = ${SNAPSHOT_INTERVAL_MS}ms"
echo "    pid file       = $PID_FILE (pid=$ERL_PID)"
echo "    working dir    = $WORK_DIR"
echo "    erl args       = $ERL_ARGS"
echo "    (Ctrl+C 退出 / ./bin/stop.sh 远程优雅退出)"
echo

# 等 erl 退出
wait "$ERL_PID"
EXIT_CODE=$?
exit "$EXIT_CODE"
