@echo off
REM stop.bat - ?????? Hermes Agent ??? (Windows ???)
REM
REM ???:
REM   bin\stop.bat            REM ?????? (rpc init:stop)
REM   bin\stop.bat -f         REM ????? (taskkill /F, ??? epmd ??????)
REM
REM ?????PID ??? (Windows ?????? erl PID), ??? rpc ??????????

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

REM ??????????? epmd ???
set "EPMD_OK=0"
where epmd >nul 2>&1
if not errorlevel 1 (
    epmd -names 2>nul | findstr /I "name %NODE_NAME%" >nul
    if not errorlevel 1 set "EPMD_OK=1"
)

if "%EPMD_OK%"=="0" (
    tasklist /FI "IMAGENAME eq erl.exe" 2>nul | find /I "erl.exe" >nul
    if errorlevel 1 (
        echo ==> Agent ????????
        if exist "%PID_FILE%" del "%PID_FILE%"
        exit /b 0
    )
    echo ==> epmd ????????%NODE_NAME%, ????????? erl.exe, ??????...
    if "%FORCE%"=="1" (
        taskkill /F /IM erl.exe >nul 2>&1
    ) else (
        taskkill /IM erl.exe >nul 2>&1
        timeout /t 2 /nobreak >nul
        tasklist /FI "IMAGENAME eq erl.exe" 2>nul | find /I "erl.exe" >nul
        if not errorlevel 1 taskkill /F /IM erl.exe >nul 2>&1
    )
    taskkill /F /IM beam.smp.exe >nul 2>&1
    if exist "%PID_FILE%" del "%PID_FILE%"
    echo ==> ??? erl ?????
    exit /b 0
)

echo ==> ?????? Agent ??? (%TARGET_NODE%)

if "%FORCE%"=="1" (
    REM ??????: ??erl.exe / beam.smp.exe ?????taskkill
    echo    [force] ??? erl ????????...
    taskkill /F /IM erl.exe >nul 2>&1
    taskkill /F /IM beam.smp.exe >nul 2>&1
    if exist "%PID_FILE%" del "%PID_FILE%"
    echo ==> ????????
    exit /b 0
)

REM ??????: rpc init:stop (15s ???)
echo    [rpc] ??? init:stop^(^) (??? 15s^)...
erl -sname "stopper_%RANDOM%" -setcookie %NODE_COOKIE% -noshell ^
    -eval "case rpc:call('%TARGET_NODE%', init, stop, [], 15000) of ok -> io:format(\"    [rpc] stop ????????n\"); {badrpc, R} -> io:format(\"    [rpc] ???: ~p~n\", [R]), halt(1) end" ^
    -s erlang halt

REM ?????? epmd ??? (????20s)
echo    [wait] ??????????..
set /a COUNT=0
:wait_loop
epmd -names 2>nul | findstr "name %NODE_NAME%" >nul
if errorlevel 1 (
    if exist "%PID_FILE%" del "%PID_FILE%"
    echo ==> Agent ????????
    exit /b 0
)
set /a COUNT+=1
if %COUNT% geq 20 goto force_kill
timeout /t 1 /nobreak >nul
goto wait_loop

:force_kill
echo    [timeout] rpc/??????, ????? erl ???...
taskkill /F /IM erl.exe >nul 2>&1
taskkill /F /IM beam.smp.exe >nul 2>&1
if exist "%PID_FILE%" del "%PID_FILE%"
echo ==> ???

endlocal
