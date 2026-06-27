@echo off
REM run-panel-session-prompt-test.bat
REM 验证 start_session 自定义 system_prompt 注入、且 history 不含 system 角色
REM 前置: start-tools.bat + start-agent.bat 已运行

setlocal
set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."

if not exist "%ROOT_DIR%\bin\run\panel.addr" (
    echo [error] panel.addr not found. Run start-agent.bat first.
    exit /b 1
)

echo [panel] EUnit session_prompt integration...
cd /d "%ROOT_DIR%\Agent-brains"
call rebar3 eunit --module=session_prompt_integration_tests
if errorlevel 1 exit /b 1

echo.
echo [panel] Live panel_e2e (get_history after start_session)...
cd /d "%ROOT_DIR%\Wails-v3"
go run ./cmd/panel_e2e
if errorlevel 1 exit /b 1

echo.
echo [ok] session_prompt: history clean + panel e2e passed
endlocal
