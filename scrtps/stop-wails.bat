@echo off
REM stop-wails.bat - 停止 Hermes Agent Workbench (Wails v3 桌面面板) - Windows
REM
REM 优雅停止: taskkill 发送 WM_CLOSE -> Wails shutdown -> bridge.ServiceShutdown
REM           -> erl init:stop (优雅退出)
REM 强制模式 (-f): taskkill /F 直接杀 (erl 子进程可能残留, 用 stop.bat 清理)
REM
REM 用法:
REM   bin\stop-wails.bat         REM 优雅停止
REM   bin\stop-wails.bat -f      REM 强制杀

setlocal

set "FORCE=0"
if "%~1"=="-f" set "FORCE=1"
if "%~1"=="--force" set "FORCE=1"

REM 检查 hermes.exe 是否在运行
tasklist /FI "IMAGENAME eq hermes.exe" 2>nul | findstr "hermes.exe" >nul
if errorlevel 1 (
    echo ==> Wails 桌面面板未运行
    exit /b 0
)

if "%FORCE%"=="1" (
    echo ==> [force] 强制杀死 Wails 进程...
    taskkill /F /IM hermes.exe >nul 2>&1
    echo ==> 已强制杀死 (erl 子进程可能残留, 用 bin\stop.bat 清理)
    exit /b 0
)

echo ==> 优雅停止 Wails 桌面面板
echo    [close] 发送 WM_CLOSE (触发 brain.Bridge.ServiceShutdown -> erl 优雅退出)...
taskkill /IM hermes.exe >nul 2>&1

REM 等 5s (Wails shutdown + bridge rpc erl init:stop + erl app terminate)
set /a COUNT=0
:wait_loop
tasklist /FI "IMAGENAME eq hermes.exe" 2>nul | findstr "hermes.exe" >nul
if errorlevel 1 (
    echo ==> Wails 已停止 (erl 已被 bridge 优雅停止)
    exit /b 0
)
set /a COUNT+=1
if %COUNT% geq 10 goto force_kill
timeout /t 1 /nobreak >nul
goto wait_loop

:force_kill
echo    [timeout] 5s 超时, 强制杀...
taskkill /F /IM hermes.exe >nul 2>&1
echo ==> 已强制杀死 Wails
echo    提示: erl 子进程可能残留, 用 bin\stop.bat 清理

endlocal
