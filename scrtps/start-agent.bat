@echo off
REM start-agent.bat - Launch Hermes Agent brain (Erlang/OTP) - Windows
REM
REM New architecture: Agent-brains is an independent process.
REM   - panel_server listens on TCP (ephemeral port), writes addr to bin/run/panel.addr
REM     for Wails to discover and connect (connection pool).
REM   - bridge_manager connects to Eion-tools via TCP connection pool,
REM     reading Eion-tools addr from bin/run/eion-tools.addr.
REM
REM Startup order (must run in this order):
REM   1. start-tools.bat   (Eion-tools server, writes eion-tools.addr)
REM   2. start-agent.bat   (this script, writes panel.addr, reads eion-tools.addr)
REM   3. start-wails.bat   (Wails GUI, reads panel.addr)
REM
REM Usage:
REM   bin\start-agent.bat                          REM default dev mode
REM   set MODE=prod ^& bin\start-agent.bat         REM production mode
REM
REM Exit: Ctrl+C (erl +B i halts) / bin\stop.bat (rpc init:stop graceful)

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "AGENT_DIR=%ROOT_DIR%\Agent-brains"
set "ERL_BIN_DIR=%ROOT_DIR%\bin\erl_bin"
set "RUN_DIR=%ROOT_DIR%\bin\run"

if "%MODE%"=="" set "MODE=dev"

REM === Mode switch: dev (default) | prod ===
if "%MODE%"=="dev" (
    set "WORK_DIR=%AGENT_DIR%"
    set "DEFAULT_MNESIA_DIR=%AGENT_DIR%\config\mnesia"
    set "DEFAULT_LOG_DIR=%AGENT_DIR%\log"
    set "DEFAULT_SYS_CONFIG=%AGENT_DIR%\config\sys.config"
)
if "%MODE%"=="prod" (
    set "WORK_DIR=%ERL_BIN_DIR%"
    set "DEFAULT_MNESIA_DIR=%ERL_BIN_DIR%\data\mnesia"
    set "DEFAULT_LOG_DIR=%ERL_BIN_DIR%\log"
    set "DEFAULT_SYS_CONFIG=%ERL_BIN_DIR%\config\sys.config"
    if not exist "%DEFAULT_SYS_CONFIG%" set "DEFAULT_SYS_CONFIG=%AGENT_DIR%\config\sys.config"
)
if not "%MODE%"=="dev" if not "%MODE%"=="prod" (
    echo ERROR: MODE must be dev or prod, got: %MODE%
    exit /b 1
)

cd /d "%WORK_DIR%"

if not exist "%ERL_BIN_DIR%" (
    echo ERROR: build artifacts missing, please run: make agent
    exit /b 1
)

REM env override (highest priority) > MODE default
if "%MNESIA_DIR%"=="" set "MNESIA_DIR=%DEFAULT_MNESIA_DIR%"
if "%LOG_DIR%"=="" set "LOG_DIR=%DEFAULT_LOG_DIR%"
if "%SYS_CONFIG%"=="" set "SYS_CONFIG=%DEFAULT_SYS_CONFIG%"
if "%SNAPSHOT_INTERVAL_MS%"=="" set "SNAPSHOT_INTERVAL_MS=60000"

REM Addr files (unified location: bin/run/)
set "PANEL_ADDR_FILE=%RUN_DIR%\panel.addr"
set "EION_TOOLS_ADDR_FILE=%RUN_DIR%\eion-tools.addr"

if not exist "%RUN_DIR%" mkdir "%RUN_DIR%"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if not exist "%MNESIA_DIR%" mkdir "%MNESIA_DIR%"

set "ERL_LIBS=%ERL_BIN_DIR%"

REM Erlang string literal treats backslash as escape char (\b=BS, \d=DEL, \e=ESC).
REM Paths passed to erl via -hermes_brains ... "path" are parsed as Erlang string
REM literals, so Windows backslashes corrupt the path. Convert to forward slashes
REM (Erlang file/filelib fully supports / on Windows). cmd syntax: %VAR:\=/%
set "PANEL_ADDR_FILE=%PANEL_ADDR_FILE:\=/%"
set "EION_TOOLS_ADDR_FILE=%EION_TOOLS_ADDR_FILE:\=/%"
set "MNESIA_DIR=%MNESIA_DIR:\=/%"
set "SYS_CONFIG=%SYS_CONFIG:\=/%"

echo ==> Starting Hermes Agent brain (mode=%MODE%, independent process)
echo    ERL_LIBS           = %ERL_LIBS%
echo    MNESIA_DIR         = %MNESIA_DIR%
echo    LOG_DIR            = %LOG_DIR%
echo    SYS_CONFIG         = %SYS_CONFIG%
echo    PANEL_ADDR_FILE    = %PANEL_ADDR_FILE%
echo    EION_TOOLS_ADDR    = %EION_TOOLS_ADDR_FILE%
if "%HERMES_EXEC_VIA_PANEL%"=="1" (
    echo    HERMES_EXEC_VIA_PANEL = 1 ^(Phase B: LLM/工具经 panel exec^)
    set "EXEC_VIA_PANEL_ARG=-hermes_brains exec_via_panel true"
) else (
    set "EXEC_VIA_PANEL_ARG="
)
echo    SNAPSHOT_INT       = %SNAPSHOT_INTERVAL_MS%ms
echo    working dir        = %WORK_DIR%
echo    (Ctrl+C to halt / bin\stop.bat for graceful exit)
echo.

REM Erlang VM tuning (aligned with start.bat):
REM   -sname/-setcookie: distributed node name + cookie, lets stop.bat rpc init:stop
REM   +B i: Ctrl+C interrupts (erl halt)
REM   snapshot_tables is a list of atoms, set via -eval before ensure_all_started.
REM
REM New architecture params (replacing old eion_tools_bin spawn):
REM   panel_addr_file     : panel_server writes listen addr here (for Wails)
REM   eion_tools_addr_file: bridge_manager reads Eion-tools addr from here (TCP pool)

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
    -hermes_brains panel_addr_file \"%PANEL_ADDR_FILE%\" ^
    -hermes_brains eion_tools_addr_file \"%EION_TOOLS_ADDR_FILE%\" ^
    %EXEC_VIA_PANEL_ARG% ^
    -hermes_brains mnesia_dir \"%MNESIA_DIR%\" ^
    -hermes_brains snapshot_interval_ms %SNAPSHOT_INTERVAL_MS% ^
    -eval "application:set_env(hermes_brains, snapshot_tables, [hermes_brains_state]), {ok, _} = application:ensure_all_started(hermes_brains), hermes_brains_app:serve()."

endlocal
