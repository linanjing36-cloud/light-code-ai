@echo off
REM run-fsm-crash-test.bat - Phase 3.1: kill agent_fsm ??transient ??????
REM ???: scrtps\start-tools.bat + api-key.json
REM Usage: scrtps\run-fsm-crash-test.bat

setlocal

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "AGENT_DIR=%ROOT_DIR%\Agent-brains"
set "ERL_BIN_DIR=%ROOT_DIR%\bin\erl_bin"
set "RUN_DIR=%ROOT_DIR%\bin\run"

if not exist "%ERL_BIN_DIR%" (
    echo ERROR: run make.ps1 agent first
    exit /b 1
)
if not exist "%RUN_DIR%\eion-tools.addr" (
    echo ERROR: start Eion-tools first: scrtps\start-tools.bat
    exit /b 1
)

set "ERL_LIBS=%ERL_BIN_DIR%"
set "EION_TOOLS_ADDR_FILE=%RUN_DIR%\eion-tools.addr"
set "EION_TOOLS_ADDR_FILE=%EION_TOOLS_ADDR_FILE:\=/%"

cd /d "%AGENT_DIR%"

echo ==> fsm_crash_recovery: kill FSM during thinking, expect transient restart
erl -noshell +B i ^
    -pa "%ERL_BIN_DIR%\hermes_brains\ebin" ^
    -config "%AGENT_DIR%\config\sys.config" ^
    -s escript start ^
    -extra scripts/fsm_crash_recovery.escript

endlocal
