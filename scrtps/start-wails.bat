@echo off
REM start-wails.bat - Launch Hermes Agent Workbench (Wails v3 GUI) - Windows
REM
REM New architecture: Wails is an independent process that connects to
REM Agent-brains (Erlang) via TCP connection pool. It no longer spawns erl.
REM
REM Wails reads bin/run/panel.addr (written by start-agent.bat) to discover
REM the panel_server address, then opens N TCP connections (connection pool).
REM
REM Startup order (must run in this order):
REM   1. start-tools.bat   (Eion-tools server)
REM   2. start-agent.bat   (Erlang brain, writes panel.addr)
REM   3. start-wails.bat   (this script, reads panel.addr)
REM
REM Usage: bin\start-wails.bat
REM Exit:  close window / bin\stop-wails.bat

setlocal

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "WAILS_BIN_DIR=%ROOT_DIR%\bin\wails_v3_bin"
set "RUN_DIR=%ROOT_DIR%\bin\run"

REM Check Wails binary
if exist "%WAILS_BIN_DIR%\hermes.exe" (
    set "BIN=%WAILS_BIN_DIR%\hermes.exe"
) else (
    echo ERROR: Wails binary not found, please run: cd Wails-v3 ^& wails3 build
    exit /b 1
)

if not exist "%RUN_DIR%" mkdir "%RUN_DIR%"

REM Tell Wails where to find panel addr file (written by start-agent.bat).
REM bridge.go resolvePanelAddr() reads HERMES_PANEL_ADDR_FILE env first,
REM then falls back to default <repo>/bin/run/panel.addr.
set "HERMES_PANEL_ADDR_FILE=%RUN_DIR%\panel.addr"

echo ==> Starting Hermes Agent Workbench (Wails v3, independent process)
echo    binary              = %BIN%
echo    HERMES_PANEL_ADDR   = %HERMES_PANEL_ADDR_FILE%
echo    (close window to exit / bin\stop-wails.bat)
echo.

start "" "%BIN%"
endlocal
