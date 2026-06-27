@echo off
REM stop-all.bat - ???????Hermes ?????? (Windows)
REM ???: .\make.ps1 stop-all

setlocal

set "SCRIPT_DIR=%~dp0"
set "FORCE=%~1"

echo.
echo ========================================
echo   Hermes ???????
echo ========================================
echo.

echo [1/3] Wails ...
call "%SCRIPT_DIR%stop-wails.bat" %FORCE%

echo [2/3] Agent-brains ...
call "%SCRIPT_DIR%stop.bat" %FORCE%
REM ???: ??? erl ???????? (?????hermes_brains ??????????????
tasklist /FI "IMAGENAME eq erl.exe" 2>nul | find /I "erl.exe" >nul
if not errorlevel 1 (
    echo        ?????? erl.exe ...
    taskkill /F /IM erl.exe >nul 2>&1
    taskkill /F /IM beam.smp.exe >nul 2>&1
)

echo [3/3] Eion-tools (bin/eion_bin) ...
tasklist /FI "IMAGENAME eq eion-tools-server.exe" 2>nul | find /I "eion-tools-server.exe" >nul
if errorlevel 1 (
    echo        ?????
) else (
    if /I "%FORCE%"=="-f" (
        taskkill /F /IM eion-tools-server.exe >nul 2>&1
    ) else (
        taskkill /IM eion-tools-server.exe >nul 2>&1
    )
    echo        ???????????
)

set "RUN_DIR=%SCRIPT_DIR%..\bin\run"
if exist "%RUN_DIR%\eion-tools.addr" del /q "%RUN_DIR%\eion-tools.addr" 2>nul
if exist "%RUN_DIR%\panel.addr" del /q "%RUN_DIR%\panel.addr" 2>nul

echo.
echo [ok] ?????????
echo.
endlocal
