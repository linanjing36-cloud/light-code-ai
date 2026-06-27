@echo off
REM start-tools.bat - Launch Eion-tools server (standalone TCP server) - Windows
REM
REM New architecture: Eion-tools is an independent TCP server process.
REM It listens on 127.0.0.1:0 (ephemeral port), writes the actual address
REM to bin/run/eion-tools.addr for Agent-brains (bridge_manager) to discover.
REM
REM Usage: bin\start-tools.bat
REM Exit:  Ctrl+C
REM
REM Frame format (aligned with Eion-tools/cmd/server/main.go):
REM   4-byte big-endian length prefix + protobuf AgentRequest/Response payload
REM Connection pool: Agent-brains bridge_manager opens N connections concurrently.

setlocal

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "EION_BIN_DIR=%ROOT_DIR%\bin\eion_bin"
set "EION_EXE=%EION_BIN_DIR%\eion-tools-server.exe"
set "RUN_DIR=%ROOT_DIR%\bin\run"

if not exist "%EION_EXE%" (
    echo ERROR: Eion-tools server not found, please run: make.ps1 tools
    echo    expected: %EION_EXE%
    exit /b 1
)

if not exist "%RUN_DIR%" mkdir "%RUN_DIR%"

REM Eion-tools server reads EION_TOOLS_ADDR_FILE env to know where to write addr
set "EION_TOOLS_ADDR_FILE=%RUN_DIR%\eion-tools.addr"

REM ?????? VM Redis Stack?????dev ???: set HERMES_MEMORY_BACKEND=dev
call "%SCRIPT_DIR%memory-env.bat"

echo [tools] Starting Eion-tools server - standalone TCP mode
echo    binary       = %EION_EXE%
echo    addr file    = %EION_TOOLS_ADDR_FILE%
echo    memory       = %HERMES_MEMORY_BACKEND% redis=%HERMES_REDIS_ADDR% mock_embed=%HERMES_MEMORY_MOCK_EMBED%
echo    protocol     = TCP, 4-byte BE length prefix + protobuf frame
echo    Ctrl+C to exit
echo.

"%EION_EXE%"

echo.
echo [tools] Eion-tools server exited, exit code = %ERRORLEVEL%
endlocal
