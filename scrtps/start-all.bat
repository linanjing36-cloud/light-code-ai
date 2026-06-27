@echo off
REM start-all.bat - ???????Hermes (Windows, ?????
REM ???: .\make.ps1 start-all  ?? .\make.ps1 start-all-ui
REM ??UI: start-all.bat wails

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
