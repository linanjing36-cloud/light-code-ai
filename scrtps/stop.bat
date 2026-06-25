@echo off
REM stop.bat - 优雅停止 Hermes Agent 大脑 (Windows 版本)
REM
REM 用法:
REM   bin\stop.bat            REM 优雅停止 (rpc init:stop)
REM   bin\stop.bat -f         REM 强制杀 (taskkill /F, 通过 epmd 反查节点)
REM
REM 不依赖 PID 文件 (Windows 下不易取 erl PID), 直接 rpc 节点名即可。

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "ERL_BIN_DIR=%ROOT_DIR%\bin\erl_bin"
set "PID_FILE=%ROOT_DIR%\Agent-brains\log\hermes_brains.pid"

set "NODE_NAME=hermes_brains"
set "NODE_COOKIE=hermes_brains"

set "FORCE=0"
if "%~1"=="-f" set "FORCE=1"
if "%~1"=="--force" set "FORCE=1"

if exist "%ERL_BIN_DIR%" set "ERL_LIBS=%ERL_BIN_DIR%"

for /f "delims=" %%H in ('hostname') do set "HOST=%%H"
set "TARGET_NODE=%NODE_NAME%@%HOST%"

REM 检查节点是否在 epmd 注册
epmd -names 2>nul | findstr "name %NODE_NAME%" >nul
if errorlevel 1 (
    echo ==> Agent 大脑未运行 (epmd 未找到节点 %NODE_NAME%)
    if exist "%PID_FILE%" del "%PID_FILE%"
    exit /b 0
)

echo ==> 优雅停止 Agent 大脑 (%TARGET_NODE%)

if "%FORCE%"=="1" (
    REM 强制模式: 找 erl.exe / beam.smp.exe 进程并 taskkill
    echo    [force] 查找 erl 进程并强杀...
    taskkill /F /IM erl.exe >nul 2>&1
    taskkill /F /IM beam.smp.exe >nul 2>&1
    if exist "%PID_FILE%" del "%PID_FILE%"
    echo ==> 已强制杀死
    exit /b 0
)

REM 优雅模式: rpc init:stop (15s 超时)
echo    [rpc] 调用 init:stop^(^) (超时 15s^)...
erl -sname "stopper_%RANDOM%" -setcookie %NODE_COOKIE% -noshell ^
    -eval "case rpc:call('%TARGET_NODE%', init, stop, [], 15000) of ok -> io:format(\"    [rpc] stop 信号已发送~n\"); {badrpc, R} -> io:format(\"    [rpc] 失败: ~p~n\", [R]), halt(1) end" ^
    -s erlang halt

REM 等节点从 epmd 消失 (最多 20s)
echo    [wait] 等待节点退出...
set /a COUNT=0
:wait_loop
epmd -names 2>nul | findstr "name %NODE_NAME%" >nul
if errorlevel 1 (
    if exist "%PID_FILE%" del "%PID_FILE%"
    echo ==> Agent 大脑已停止
    exit /b 0
)
set /a COUNT+=1
if %COUNT% geq 20 goto force_kill
timeout /t 1 /nobreak >nul
goto wait_loop

:force_kill
echo    [timeout] rpc/等待超时, 强制杀 erl 进程...
taskkill /F /IM erl.exe >nul 2>&1
taskkill /F /IM beam.smp.exe >nul 2>&1
if exist "%PID_FILE%" del "%PID_FILE%"
echo ==> 完成

endlocal
