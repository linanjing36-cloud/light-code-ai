@echo off
REM start.bat - 启动 Hermes Agent 大脑 (Erlang/OTP) - Windows 版本
REM
REM 用法:
REM   bin\start.bat                              REM 默认开发模式 (MODE=dev)
REM   set MODE=prod ^& bin\start.bat             REM 发布模式
REM   set MNESIA_DIR=C:\custom\path ^& bin\start.bat  REM 覆盖 mnesia 目录
REM
REM 模式切换 (MODE=dev^|prod):
REM   dev  (默认): WORK_DIR=Agent-brains\, mnesia 在 config\mnesia\
REM   prod       : WORK_DIR=bin\erl_bin\, mnesia 在 data\mnesia\
REM                (sys.config 用 bin\erl_bin\config\sys.config)
REM
REM 退出: Ctrl+C (erl +B i 直接 halt) / bin\stop.bat (rpc init:stop 优雅)

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "AGENT_DIR=%ROOT_DIR%\Agent-brains"
set "ERL_BIN_DIR=%ROOT_DIR%\bin\erl_bin"
set "EION_BIN_DIR=%ROOT_DIR%\bin\eion_bin"

if "%MODE%"=="" set "MODE=dev"

REM === 模式切换: dev (默认) | prod ===
if "%MODE%"=="dev" (
    set "WORK_DIR=%AGENT_DIR%"
    set "DEFAULT_MNESIA_DIR=%AGENT_DIR%\config\mnesia"
    set "DEFAULT_LOG_DIR=%AGENT_DIR%\log"
    set "DEFAULT_EION_TOOLS_BIN=%EION_BIN_DIR%\eion-tools-server.exe"
    set "DEFAULT_SYS_CONFIG=%AGENT_DIR%\config\sys.config"
)
if "%MODE%"=="prod" (
    set "WORK_DIR=%ERL_BIN_DIR%"
    set "DEFAULT_MNESIA_DIR=%ERL_BIN_DIR%\data\mnesia"
    set "DEFAULT_LOG_DIR=%ERL_BIN_DIR%\log"
    set "DEFAULT_EION_TOOLS_BIN=%EION_BIN_DIR%\eion-tools-server.exe"
    set "DEFAULT_SYS_CONFIG=%ERL_BIN_DIR%\config\sys.config"
    if not exist "%DEFAULT_SYS_CONFIG%" set "DEFAULT_SYS_CONFIG=%AGENT_DIR%\config\sys.config"
)
if not "%MODE%"=="dev" if not "%MODE%"=="prod" (
    echo ERROR: MODE 必须是 dev 或 prod, 当前: %MODE%
    exit /b 1
)

cd /d "%WORK_DIR%"

if not exist "%ERL_BIN_DIR%" (
    echo ERROR: 编译产物不存在, 请先执行: make agent
    exit /b 1
)

REM 环境变量覆盖 (优先级最高) > MODE 默认值
if "%MNESIA_DIR%"=="" set "MNESIA_DIR=%DEFAULT_MNESIA_DIR%"
if "%LOG_DIR%"=="" set "LOG_DIR=%DEFAULT_LOG_DIR%"
if "%EION_TOOLS_BIN%"=="" set "EION_TOOLS_BIN=%DEFAULT_EION_TOOLS_BIN%"
if "%SYS_CONFIG%"=="" set "SYS_CONFIG=%DEFAULT_SYS_CONFIG%"
if "%SNAPSHOT_INTERVAL_MS%"=="" set "SNAPSHOT_INTERVAL_MS=60000"

set "ERL_LIBS=%ERL_BIN_DIR%"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if not exist "%MNESIA_DIR%" mkdir "%MNESIA_DIR%"

echo ==> 启动 Hermes Agent 大脑 (mode=%MODE%)
echo    ERL_LIBS       = %ERL_LIBS%
echo    MNESIA_DIR     = %MNESIA_DIR%
echo    LOG_DIR        = %LOG_DIR%
echo    SYS_CONFIG     = %SYS_CONFIG%
echo    EION_TOOLS_BIN = %EION_TOOLS_BIN%
echo    SNAPSHOT_INT   = %SNAPSHOT_INTERVAL_MS%ms
echo    working dir    = %WORK_DIR%
echo    (Ctrl+C 退出 / bin\stop.bat 优雅退出)
echo.

REM Erlang VM 优化启动参数 (与 start.sh 对齐, 注释见 start.sh)
REM snapshot_tables 是 list of atoms, 不能用 -App Key Value (只接受 string),
REM 必须在 -eval 里用 application:set_env 设置, 在 ensure_all_started 之前生效。
REM -sname/-setcookie: 分布式节点名 + cookie, 让 stop.bat 可以 rpc init:stop
REM +B i: Ctrl+C 直接 interrupt (erl halt), 优雅退出请用 bin\stop.bat
REM (Windows 下不写 PID 文件, stop.bat 用 rpc + epmd 反查节点状态)

erl ^
    -noinput +B i ^
    -sname hermes_brains ^
    -setcookie hermes_brains ^
    +K true +A 128 +P 1048576 ^
    +sbwt none +sbwtdcpu none +sbwtdio none ^
    +zdbbl 8192 ^
    -env ERL_CRASH_DUMP "%LOG_DIR%\erl_crash.dump" ^
    -kernel net_ticktime 60 ^
    -config "%SYS_CONFIG%" ^
    -hermes_brains eion_tools_bin "%EION_TOOLS_BIN%" ^
    -hermes_brains mnesia_dir "%MNESIA_DIR%" ^
    -hermes_brains snapshot_interval_ms %SNAPSHOT_INTERVAL_MS% ^
    -eval "application:set_env(hermes_brains, snapshot_tables, [hermes_brains_state]), {ok, _} = application:ensure_all_started(hermes_brains)"

endlocal
