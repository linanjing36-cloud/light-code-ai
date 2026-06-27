@echo off
REM run-memory-demo.bat - Step 4.1a 端到端: ReAct + memory_store/memory_search
REM
REM 前置:
REM   1. VM Redis Stack 运行中 (192.168.59.129:6379)
REM   2. api-key.json (DeepSeek LLM)
REM
REM 本地 dev 后端: set HERMES_MEMORY_BACKEND=dev 后再运行

setlocal

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "AGENT_DIR=%ROOT_DIR%\Agent-brains"
set "ERL_BIN_DIR=%ROOT_DIR%\bin\erl_bin"
set "EION_BIN_DIR=%ROOT_DIR%\bin\eion_bin"
set "RUN_DIR=%ROOT_DIR%\bin\run"
set "EION_EXE=%EION_BIN_DIR%\eion-tools-server.exe"
set "EION_ADDR_FILE=%RUN_DIR%\eion-tools.addr"

call "%SCRIPT_DIR%memory-env.bat"

if not exist "%ERL_BIN_DIR%" (
    echo ERROR: run make.ps1 agent first
    exit /b 1
)

if not exist "%EION_EXE%" (
    echo ERROR: run make.ps1 tools first
    exit /b 1
)

if not exist "%RUN_DIR%" mkdir "%RUN_DIR%"
set "EION_TOOLS_ADDR_FILE=%RUN_DIR%\eion-tools.addr"

if /I not "%HERMES_MEMORY_BACKEND%"=="dev" (
    echo [demo] Step 1: check VM Redis Stack
    call "%SCRIPT_DIR%check-redis-vm.bat"
    if errorlevel 1 exit /b 1
) else (
    echo [demo] Step 1: dev backend - skip Redis check
)

echo.
echo [demo] Step 2: start Eion-tools with memory tools - background
tasklist /FI "IMAGENAME eq eion-tools-server.exe" 2>nul | find /I "eion-tools-server.exe" >nul
if errorlevel 1 (
    start "eion-tools" /D "%EION_BIN_DIR%" cmd /c "set HERMES_MEMORY_BACKEND=%HERMES_MEMORY_BACKEND%&& set HERMES_MEMORY_MOCK_EMBED=%HERMES_MEMORY_MOCK_EMBED%&& set HERMES_EMBEDDING_DIM=%HERMES_EMBEDDING_DIM%&& set HERMES_REDIS_ADDR=%HERMES_REDIS_ADDR%&& set EION_TOOLS_ADDR_FILE=%EION_TOOLS_ADDR_FILE%&& eion-tools-server.exe"
    timeout /t 2 /nobreak >nul
) else (
    echo    eion-tools already running - restart manually if env changed
)

if not exist "%EION_ADDR_FILE%" (
    echo ERROR: eion-tools addr file missing, wait and retry
    exit /b 1
)

set "ERL_LIBS=%ERL_BIN_DIR%"
set "EION_TOOLS_ADDR_FILE=%EION_ADDR_FILE:\=/%"

cd /d "%AGENT_DIR%"

echo.
echo [demo] Step 3: agent_memory_demo - ReAct + memory tools
erl -noshell +B i ^
    -pa "%ERL_BIN_DIR%\hermes_brains\ebin" ^
    -config "%AGENT_DIR%\config\sys.config" ^
    -eval "agent_memory_demo:run()."

endlocal
