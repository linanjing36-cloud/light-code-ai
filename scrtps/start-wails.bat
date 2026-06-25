@echo off
REM start-wails.bat - 启动 Hermes Agent Workbench (Wails v3 桌面面板) - Windows
REM
REM Wails 进程会通过 brain.Bridge.ServiceStartup 自动 spawn Erlang 子进程,
REM 不需要先运行 start.bat。
REM
REM 用法: bin\start-wails.bat
REM
REM 退出: 关闭窗口 / bin\stop-wails.bat
REM
REM 注意: 不要与 start.bat 同时运行! 两者都会启动 erl (sname=hermes_brains),
REM       会导致节点名冲突。二选一:
REM         · 桌面面板模式: start-wails.bat (Wails 管理 erl 生命周期)
REM         · 纯命令行模式: start.bat (独立 erl, 无 GUI)

setlocal

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "WAILS_BIN_DIR=%ROOT_DIR%\bin\wails_v3_bin"
set "ERL_BIN_DIR=%ROOT_DIR%\bin\erl_bin"

REM 检查 Wails 编译产物
if exist "%WAILS_BIN_DIR%\hermes.exe" (
    set "BIN=%WAILS_BIN_DIR%\hermes.exe"
) else (
    echo ERROR: Wails 编译产物不存在, 请先执行:
    echo    cd Wails-v3 ^&^& wails3 build
    exit /b 1
)

REM 检查 Erlang 编译产物
if not exist "%ERL_BIN_DIR%" (
    echo ERROR: Erlang 编译产物不存在, 请先执行: make agent
    exit /b 1
)

REM 关键: 设置环境变量, 让 bridge.go 不依赖 cwd
REM workDir()         优先读 HERMES_DATA_DIR
REM agentBrainsLibDir() 优先读 HERMES_ERL_LIBS
set "HERMES_ERL_LIBS=%ERL_BIN_DIR%"
set "HERMES_DATA_DIR=%ERL_BIN_DIR%"
set "MODE=prod"

echo ==> 启动 Hermes Agent Workbench (Wails v3)
echo    binary         = %BIN%
echo    HERMES_ERL_LIBS = %HERMES_ERL_LIBS%
echo    HERMES_DATA_DIR = %HERMES_DATA_DIR%
echo    (关闭窗口退出 / bin\stop-wails.bat 优雅退出)
echo.

start "" "%BIN%"
endlocal
