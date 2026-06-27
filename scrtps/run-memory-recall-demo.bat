@echo off
setlocal EnableDelayedExpansion
REM run-memory-recall-demo.bat - Step 4.1 ????????????
REM ???: VM Redis Stack + start-tools.bat (HERMES_MEMORY_BACKEND=redis)

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "AGENT_DIR=%ROOT_DIR%\Agent-brains"
set "ERL_BIN_DIR=%ROOT_DIR%\bin\erl_bin"

call "%SCRIPT_DIR%memory-env.bat"
call "%SCRIPT_DIR%check-redis-vm.bat"
if errorlevel 1 exit /b 1

if not exist "%ERL_BIN_DIR%" (
    echo ERROR: run make.ps1 agent first
    exit /b 1
)

set "ERL_LIBS=%ERL_BIN_DIR%"
cd /d "%AGENT_DIR%"

echo [recall-demo] ReAct + RAG prefetch recall test
erl -noshell +B i ^
    -pa "%ERL_BIN_DIR%\hermes_brains\ebin" ^
    -config "%AGENT_DIR%\config\sys.config" ^
    -eval "agent_memory_recall_demo:run()."

set "TEST_RC=!ERRORLEVEL!"
endlocal & exit /b %TEST_RC%
