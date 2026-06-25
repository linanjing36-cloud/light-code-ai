@echo off
REM start.bat - Launch Hermes Agent brain (Erlang/OTP) - Windows
REM
REM Usage:
REM   bin\start.bat                              REM default dev mode
REM   set MODE=prod ^& bin\start.bat             REM production mode
REM   set MNESIA_DIR=C:\custom\path ^& bin\start.bat  REM override mnesia dir
REM
REM Mode switch (MODE=dev^|prod):
REM   dev  (default): WORK_DIR=Agent-brains\, mnesia in config\mnesia\
REM   prod         : WORK_DIR=bin\erl_bin\, mnesia in data\mnesia\
REM                   (sys.config from bin\erl_bin\config\sys.config)
REM
REM Exit: Ctrl+C (erl +B i halts) / bin\stop.bat (rpc init:stop graceful)

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "AGENT_DIR=%ROOT_DIR%\Agent-brains"
set "ERL_BIN_DIR=%ROOT_DIR%\bin\erl_bin"
set "EION_BIN_DIR=%ROOT_DIR%\bin\eion_bin"

if "%MODE%"=="" set "MODE=dev"

REM === Mode switch: dev (default) | prod ===
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
if "%EION_TOOLS_BIN%"=="" set "EION_TOOLS_BIN=%DEFAULT_EION_TOOLS_BIN%"
if "%SYS_CONFIG%"=="" set "SYS_CONFIG=%DEFAULT_SYS_CONFIG%"
if "%SNAPSHOT_INTERVAL_MS%"=="" set "SNAPSHOT_INTERVAL_MS=60000"

set "ERL_LIBS=%ERL_BIN_DIR%"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
if not exist "%MNESIA_DIR%" mkdir "%MNESIA_DIR%"

REM Erlang string literal treats backslash as escape char (\b=BS, \d=DEL, \e=ESC).
REM Paths passed to erl via -hermes_brains ... "path" are parsed as Erlang string
REM literals, so Windows backslashes corrupt the path (e:\bin\data -> e:[BS]in[DEL]ata),
REM causing filelib:ensure_dir to return {error, enoent}. Convert to forward slashes
REM (Erlang file/filelib fully supports / on Windows). cmd syntax: %VAR:\=/%
set "EION_TOOLS_BIN=%EION_TOOLS_BIN:\=/%"
set "MNESIA_DIR=%MNESIA_DIR:\=/%"
set "SYS_CONFIG=%SYS_CONFIG:\=/%"

echo ==> Starting Hermes Agent brain (mode=%MODE%)
echo    ERL_LIBS       = %ERL_LIBS%
echo    MNESIA_DIR     = %MNESIA_DIR%
echo    LOG_DIR        = %LOG_DIR%
echo    SYS_CONFIG     = %SYS_CONFIG%
echo    EION_TOOLS_BIN = %EION_TOOLS_BIN%
echo    SNAPSHOT_INT   = %SNAPSHOT_INTERVAL_MS%ms
echo    working dir    = %WORK_DIR%
echo    (Ctrl+C to halt / bin\stop.bat for graceful exit)
echo.

REM Erlang VM tuning (aligned with start.sh, see start.sh for comments)
REM snapshot_tables is a list of atoms, cannot use -App Key Value (string only),
REM must set via application:set_env in -eval before ensure_all_started.
REM -sname/-setcookie: distributed node name + cookie, lets stop.bat rpc init:stop
REM +B i: Ctrl+C interrupts (erl halt), use bin\stop.bat for graceful exit
REM (Windows: no PID file, stop.bat uses rpc + epmd to query node state)

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
    -hermes_brains eion_tools_bin \"%EION_TOOLS_BIN%\" ^
    -hermes_brains mnesia_dir \"%MNESIA_DIR%\" ^
    -hermes_brains snapshot_interval_ms %SNAPSHOT_INTERVAL_MS% ^
    -eval "application:set_env(hermes_brains, snapshot_tables, [hermes_brains_state]), {ok, _} = application:ensure_all_started(hermes_brains)"

endlocal
