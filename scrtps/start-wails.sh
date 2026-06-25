#!/usr/bin/env bash
# start-wails.sh - 启动 Hermes Agent Workbench (Wails v3 桌面面板)
#
# Wails 进程会通过 brain.Bridge.ServiceStartup 自动 spawn Erlang 子进程
# (hermes_brains), 不需要先运行 start.sh。Wails 退出时 bridge.ServiceShutdown
# 会 rpc init:stop 优雅停止 erl。
#
# 用法:
#   ./bin/start-wails.sh            # 启动 Wails 桌面面板 (会自动拉起 erl)
#   ./bin/start-wails.sh &          # 后台启动
#
# 退出:
#   关闭窗口             : Wails 退出 (ApplicationShouldTerminateAfterLastWindowClosed)
#   ./bin/stop-wails.sh  : 优雅停止 (SIGTERM -> bridge.ServiceShutdown -> erl init:stop)
#   ./bin/stop-wails.sh -f : 强制杀 (SIGKILL)
#
# 注意: 不要与 start.sh 同时运行! start.sh 会独立启动 erl (sname=hermes_brains),
#       而 Wails 的 bridge 也会 spawn 同名 erl, 导致 -sname 冲突。
#       两种模式二选一:
#         · 桌面面板模式: start-wails.sh (Wails 管理 erl 生命周期)
#         · 纯命令行模式: start.sh (独立 erl, 无 GUI)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WAILS_BIN_DIR="$ROOT_DIR/bin/wails_v3_bin"
ERL_BIN_DIR="$ROOT_DIR/bin/erl_bin"

# 检查 Wails 编译产物
APP_BUNDLE="$WAILS_BIN_DIR/hermes.app/Contents/MacOS/hermes"  # wails3 package 产出
PLAIN_BIN="$WAILS_BIN_DIR/hermes"                              # wails3 build 产出

if [ ! -x "$APP_BUNDLE" ] && [ ! -x "$PLAIN_BIN" ]; then
    echo "ERROR: Wails 编译产物不存在, 请先执行:" >&2
    echo "    cd Wails-v3 && wails3 build       # 产出 bin/wails_v3_bin/hermes" >&2
    echo "    cd Wails-v3 && wails3 package     # 产出 bin/wails_v3_bin/hermes.app" >&2
    exit 1
fi

# 检查 Erlang 编译产物 (bridge 会 spawn erl, 必须存在)
if [ ! -d "$ERL_BIN_DIR" ]; then
    echo "ERROR: Erlang 编译产物不存在, 请先执行: make agent" >&2
    exit 1
fi

# === 关键: 设置环境变量, 让 bridge.go 不依赖 cwd ===
# workDir()         优先读 HERMES_DATA_DIR
# agentBrainsLibDir() 优先读 HERMES_ERL_LIBS
# 这样无论从哪个目录启动 start-wails.sh, bridge 都能正确找到 bin/erl_bin
export HERMES_ERL_LIBS="$ERL_BIN_DIR"
export HERMES_DATA_DIR="$ERL_BIN_DIR"
export MODE=prod

# 选择可执行文件: 优先 .app bundle (有图标/Info.plist), 退化到裸二进制
if [ -x "$APP_BUNDLE" ]; then
    BIN="$APP_BUNDLE"
else
    BIN="$PLAIN_BIN"
fi

echo "==> 启动 Hermes Agent Workbench (Wails v3)"
echo "    binary         = $BIN"
echo "    HERMES_ERL_LIBS = $HERMES_ERL_LIBS"
echo "    HERMES_DATA_DIR = $HERMES_DATA_DIR"
echo "    (关闭窗口退出 / ./bin/stop-wails.sh 优雅退出)"
echo

exec "$BIN"
