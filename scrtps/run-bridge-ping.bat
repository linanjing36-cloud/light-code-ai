@echo off
REM run-bridge-ping.bat - Step 1.3 联调: Erlang bridge_manager -> Eion-tools LLM 单点 ping
REM
REM 前置: scrtps\start-tools.bat 已运行 (写入 bin\run\eion-tools.addr)
REM 凭证: 项目根 api-key.json 或环境变量 API_KEY_FILE
REM
REM Usage: scrtps\run-bridge-ping.bat

setlocal

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "AGENT_DIR=%ROOT_DIR%\Agent-brains"
set "ERL_BIN_DIR=%ROOT_DIR%\bin\erl_bin"
set "RUN_DIR=%ROOT_DIR%\bin\run"
set "EION_ADDR_FILE=%RUN_DIR%\eion-tools.addr"

if not exist "%ERL_BIN_DIR%" (
    echo ERROR: run make.ps1 agent first
    exit /b 1
)

if not exist "%EION_ADDR_FILE%" (
    echo ERROR: Eion-tools not running? Start: scrtps\start-tools.bat
    exit /b 1
)

set "ERL_LIBS=%ERL_BIN_DIR%"
set "EION_TOOLS_ADDR_FILE=%EION_ADDR_FILE:\=/%"

cd /d "%AGENT_DIR%"

echo ==> bridge_ping: Erlang -^> Eion-tools LLM ping
echo    ERL_LIBS=%ERL_LIBS%
echo    EION_TOOLS_ADDR_FILE=%EION_TOOLS_ADDR_FILE%
echo.

erl -noshell +B i ^
    -pa "%ERL_BIN_DIR%\hermes_brains\ebin" ^
    -config "%AGENT_DIR%\config\sys.config" ^
    -eval "bridge_ping:run()."

endlocal
