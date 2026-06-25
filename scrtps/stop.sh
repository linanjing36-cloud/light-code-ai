#!/usr/bin/env bash
# stop.sh - 优雅停止 Hermes Agent 大脑
#
# 用法:
#   ./bin/stop.sh                # 默认停止 (dev 模式, PID 在 Agent-brains/log/)
#   MODE=prod ./bin/stop.sh      # 停止 prod 模式实例 (PID 在 bin/erl_bin/log/)
#   NODE_NAME=foo ./bin/stop.sh  # 自定义节点名
#   ./bin/stop.sh -f            # 强制杀 (跳过 rpc, 直接 kill -KILL)
#
# 优雅退出顺序 (rpc init:stop/0 触发):
#   init:stop()
#     -> application:stop(hermes_brains)
#        -> hermes_brains_sup 按子进程逆序 terminate:
#             agent_sup         -> 关闭所有 FSM
#             bridge_manager    -> port_close (Go 进程退出)
#             state_store       -> (无 terminate 逻辑, ETS 自然销毁)
#             mnesia_store      -> timing_wheel:cancel(periodic ref) + mnesia 不停 (由 .app.src 控制)
#             timing_wheel      -> (无 terminate 逻辑)
#     -> erlang VM halt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_DIR="$ROOT_DIR/Agent-brains"
ERL_BIN_DIR="$ROOT_DIR/bin/erl_bin"

# === 模式切换 (与 start.sh 一致, 用于定位 PID 文件) ===
# dev (默认): PID 文件在 Agent-brains/log/
# prod       : PID 文件在 bin/erl_bin/log/
MODE="${MODE:-dev}"
case "$MODE" in
    dev)  DEFAULT_LOG_DIR="$AGENT_DIR/log" ;;
    prod) DEFAULT_LOG_DIR="$ERL_BIN_DIR/log" ;;
    *) echo "ERROR: MODE 必须是 dev 或 prod, 当前: $MODE" >&2; exit 1 ;;
esac
LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
PID_FILE="$LOG_DIR/hermes_brains.pid"

# 节点名 + cookie (必须与 start.sh 一致, 才能 rpc:call)
NODE_NAME="${NODE_NAME:-hermes_brains}"
NODE_COOKIE="${NODE_COOKIE:-hermes_brains}"
HOST=$(hostname -s)
TARGET_NODE="$NODE_NAME@$HOST"

FORCE=0
if [ "${1:-}" = "-f" ] || [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

# 读取 PID 文件
PID=""
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
fi

# PID 不存在或进程已死, 直接清理 PID 文件并退出
if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
    echo "==> Agent 大脑未运行 (PID 文件不存在或进程已死)"
    rm -f "$PID_FILE"
    # 兜底: 检查 epmd 是否还有 hermes_brains 节点 (可能 start.sh 没正常退出)
    if command -v epmd >/dev/null 2>&1; then
        if epmd -names 2>/dev/null | grep -q "name $NODE_NAME"; then
            echo "==> 检测到 epmd 仍有节点 $NODE_NAME, 尝试 rpc 停止..."
        else
            exit 0
        fi
    else
        exit 0
    fi
fi

echo "==> 优雅停止 Agent 大脑 ($TARGET_NODE, pid=${PID:-unknown})"

# === 强制模式: 直接 SIGKILL ===
if [ "$FORCE" = "1" ] && [ -n "$PID" ]; then
    echo "    [force] 发送 SIGKILL..."
    kill -KILL "$PID" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "==> 已强制杀死"
    exit 0
fi

# === 优雅模式: rpc:call(init, stop) ===
# 启动一次性 stopper 节点, 用同 cookie rpc 调用目标的 init:stop/0
# init:stop/0 会触发所有 application 的 terminate, 是真正的优雅退出
# 超时 15s (应用 terminate + mnesia 落盘 + port_close 等)
if [ -d "$ERL_BIN_DIR" ]; then
    export ERL_LIBS="$ERL_BIN_DIR"
fi

echo "    [rpc] 调用 init:stop() (超时 15s)..."
erl -sname "stopper_$$" -setcookie "$NODE_COOKIE" -noshell \
    -eval "
        case rpc:call('$TARGET_NODE', init, stop, [], 15000) of
            ok -> io:format(\"    [rpc] stop 信号已发送, 等待应用 terminate...~n\");
            {badrpc, Reason} ->
                io:format(\"    [rpc] 失败: ~p~n\", [Reason]),
                halt(1)
        end
    " \
    -s erlang halt 2>&1 | sed 's/^/    /' || true

# === 等 PID 退出 (最多 20s) ===
if [ -n "$PID" ]; then
    echo "    [wait] 等待 pid $PID 退出..."
    for i in $(seq 1 40); do
        if ! kill -0 "$PID" 2>/dev/null; then
            rm -f "$PID_FILE"
            echo "==> Agent 大脑已停止 (耗时 ${i}x0.5s)"
            exit 0
        fi
        sleep 0.5
    done
    # 超时, 升级为 SIGTERM
    echo "    [timeout] rpc/等待超时, 发送 SIGTERM..."
    kill -TERM "$PID" 2>/dev/null || true
    sleep 2
    if kill -0 "$PID" 2>/dev/null; then
        echo "    [timeout] 仍存活, 发送 SIGKILL..."
        kill -KILL "$PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
fi

echo "==> 完成"
