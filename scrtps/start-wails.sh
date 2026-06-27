#!/usr/bin/env bash
# start-wails.sh - 启动 Hermes Agent Workbench (Wails v3 桌面面板)
#
# 当前架构下，Wails 是独立进程，只连接已启动的 Agent-brains。
# 推荐先运行 start-agent.sh / start-agent.bat 写出 panel.addr，再启动 Wails。
# embedded Eion-tools 由 hermes 进程内启动，不需要单独 start-tools。
#
# 用法:
#   ./bin/start-wails.sh            # 启动 Wails 桌面面板 (连接已有 Agent-brains)
#   ./bin/start-wails.sh &          # 后台启动
#
# 退出:
#   关闭窗口             : Wails 退出 (ApplicationShouldTerminateAfterLastWindowClosed)
#   ./bin/stop-wails.sh  : 优雅停止 Wails；Agent 如需停止请单独执行 ./bin/stop.sh
#   ./bin/stop-wails.sh -f : 强制杀 (SIGKILL)
#
# 推荐顺序:
#   1. start-agent.sh / start-agent.bat
#   2. start-wails.sh
#
# 纯命令行模式可单独运行 start.sh；若走独立 tools 模式，则先启动 tools 再启动 Agent。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WAILS_BIN_DIR="$ROOT_DIR/bin/wails_v3_bin"
RUN_DIR="$ROOT_DIR/bin/run"

# 检查 Wails 编译产物
APP_BUNDLE="$WAILS_BIN_DIR/hermes.app/Contents/MacOS/hermes"  # wails3 package 产出
PLAIN_BIN="$WAILS_BIN_DIR/hermes"                              # wails3 build 产出

if [ ! -x "$APP_BUNDLE" ] && [ ! -x "$PLAIN_BIN" ]; then
    echo "ERROR: Wails 编译产物不存在, 请先执行:" >&2
    echo "    cd Wails-v3 && wails3 build       # 产出 bin/wails_v3_bin/hermes" >&2
    echo "    cd Wails-v3 && wails3 package     # 产出 bin/wails_v3_bin/hermes.app" >&2
    exit 1
fi

mkdir -p "$RUN_DIR"

# 显式传入地址文件路径，和 Windows start-wails.bat 保持一致。
export EION_TOOLS_ADDR_FILE="$RUN_DIR/eion-tools.addr"
export HERMES_EION_ADDR_FILE="$RUN_DIR/eion-tools.addr"
export HERMES_PANEL_ADDR_FILE="$RUN_DIR/panel.addr"
export HERMES_EXEC_VIA_PANEL=1

# 选择可执行文件: 优先 .app bundle (有图标/Info.plist), 退化到裸二进制
if [ -x "$APP_BUNDLE" ]; then
    BIN="$APP_BUNDLE"
else
    BIN="$PLAIN_BIN"
fi

echo "==> 启动 Hermes Agent Workbench (Wails v3)"
echo "    binary                = $BIN"
echo "    EION_TOOLS_ADDR_FILE  = $EION_TOOLS_ADDR_FILE"
echo "    HERMES_PANEL_ADDR_FILE = $HERMES_PANEL_ADDR_FILE"
echo "    HERMES_EXEC_VIA_PANEL = $HERMES_EXEC_VIA_PANEL"
echo "    (关闭窗口退出 / ./bin/stop-wails.sh 关闭 Wails)"
echo

exec "$BIN"
