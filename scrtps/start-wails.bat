@echo off
REM start-wails.bat - Launch Hermes Agent Workbench (Wails v3 GUI) - Windows
REM
REM New architecture: Wails is an independent process that connects to
REM Agent-brains (Erlang) via TCP connection pool. It no longer spawns erl.
REM
REM Wails reads bin/run/panel.addr (written by start-agent.bat) to discover
REM the panel_server address, then opens N TCP connections (connection pool).
REM
REM Startup order in panel-exec mode (recommended):
REM   1. start-agent.bat   (Erlang brain, writes panel.addr)
REM   2. start-wails.bat   (Wails + embedded Eion-tools, reads panel.addr)
REM
REM Note:
REM   In HERMES_EXEC_VIA_PANEL=1 mode, Agent-brains does not depend on
REM   eion-tools.addr at startup time. embedded Eion is started in hermes.exe
REM   and serves panel exec requests in-process.
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

REM Eion-tools 已嵌入 hermes.exe；写 addr 供 Agent-brains bridge_manager 发现。
set "EION_TOOLS_ADDR_FILE=%RUN_DIR%\eion-tools.addr"
set "HERMES_EION_ADDR_FILE=%RUN_DIR%\eion-tools.addr"

REM Tell Wails where to find panel addr file (written by start-agent.bat).
REM bridge.go resolvePanelAddr() reads HERMES_PANEL_ADDR_FILE env first,
REM then falls back to default <repo>/bin/run/panel.addr.
set "HERMES_PANEL_ADDR_FILE=%RUN_DIR%\panel.addr"
set "HERMES_EXEC_VIA_PANEL=1"

echo ==> Starting Hermes Agent Workbench (Wails v3, Eion-tools embedded)
echo    binary              = %BIN%
echo    EION_TOOLS_ADDR     = %EION_TOOLS_ADDR_FILE%
echo    HERMES_PANEL_ADDR   = %HERMES_PANEL_ADDR_FILE%
echo    HERMES_EXEC_VIA_PANEL = 1
echo    (close window to exit / bin\stop-wails.bat)
echo.

start "" "%BIN%"
endlocal
