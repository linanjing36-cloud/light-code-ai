#!/usr/bin/env bash
# stop-wails.sh - 停止 Hermes Agent Workbench (Wails v3 桌面面板)
#
# 优雅退出顺序 (SIGTERM 触发):
#   SIGTERM -> Wails app shutdown
#     -> brain.Bridge.ServiceShutdown()
#        -> 关闭 bridge 连接
#     -> Wails 进程退出
# Agent 如需停止，请单独执行 ./bin/stop.sh 或 stop-all
#
# 用法:
#   ./bin/stop-wails.sh         # 优雅停止 Wails (SIGTERM, 5s 超时)
#   ./bin/stop-wails.sh -f      # 强制杀 Wails (SIGKILL)

set -euo pipefail

FORCE=0
if [ "${1:-}" = "-f" ] || [ "${1:-}" = "--force" ]; then
    FORCE=1
fi

# 查找 Wails 进程 (hermes 二进制, 排除 erl 的 hermes_brains 节点)
# 匹配 bin/wails_v3_bin/hermes 路径, 避免误杀其他同名进程
PIDS=$(pgrep -f "wails_v3_bin/hermes" 2>/dev/null || true)

if [ -z "$PIDS" ]; then
    echo "==> Wails 桌面面板未运行"
    exit 0
fi

if [ "$FORCE" = "1" ]; then
    echo "==> [force] 强制杀死 Wails 进程: $PIDS"
    kill -KILL $PIDS 2>/dev/null || true
    echo "==> 已强制杀死 (erl 子进程可能残留, 用 ./bin/stop.sh 清理)"
    exit 0
fi

echo "==> 优雅停止 Wails 桌面面板 (pid=$PIDS)"
echo "    [term] 发送 SIGTERM (触发 brain.Bridge.ServiceShutdown, 关闭 Wails)..."

kill -TERM $PIDS 2>/dev/null || true

# 等 Wails 退出 (最多 10s)
for i in $(seq 1 20); do
    if ! kill -0 $PIDS 2>/dev/null; then
        echo "==> Wails 已停止"
        exit 0
    fi
    sleep 0.5
done

# 超时, 升级为 SIGKILL
echo "    [timeout] 10s 超时, 升级为 SIGKILL..."
kill -KILL $PIDS 2>/dev/null || true
echo "==> 已强制杀死 Wails"
echo "    提示: Agent 进程可能仍在, 用 ./bin/stop.sh 或 stop-all 清理"
