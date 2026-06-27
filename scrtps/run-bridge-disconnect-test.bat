@echo off
REM run-bridge-disconnect-test.bat - Phase 3.2: ??? Eion-tools ??? bridge_disconnect ???
REM
REM ???: LLM ?????Eion-tools (Eino) ???; Erlang ??bridge_manager ??LLMInferRequest??
REM ?????? thinking ??? Eion-tools ????????eion-tools-server.exe??
REM
REM ???: scrtps\start-tools.bat + api-key.json
REM ????? ?????? scrtps\start-tools.bat (????????? Eion-tools)
REM
REM Usage: scrtps\run-bridge-disconnect-test.bat

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

echo ==> bridge_disconnect_test: kill Eion-tools during LLMInferRequest
echo    LLM API call lives in Eion-tools, not Erlang
echo.

erl -noshell +B i ^
    -pa "%ERL_BIN_DIR%\hermes_brains\ebin" ^
    -config "%AGENT_DIR%\config\sys.config" ^
    -s escript start ^
    -extra scripts/bridge_disconnect_test.escript

endlocal
