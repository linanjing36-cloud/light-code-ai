@echo off
REM start-all.bat - 一键启动 Hermes (Windows, 薄包装)
REM 推荐: .\make.ps1 start-all  或  .\make.ps1 start-all-ui
REM 带 UI: start-all.bat wails

setlocal
set "SCRIPT_DIR=%~dp0"
set "ARG=%~1"
if /I "%ARG%"=="wails" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\make.ps1" start-all-ui
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\make.ps1" start-all
)
endlocal
exit /b %ERRORLEVEL%
