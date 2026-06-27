@echo off
REM check-redis-vm.bat - 检测 VM Redis Stack 是否可达

setlocal

call "%~dp0memory-env.bat"

for /f "tokens=1,2 delims=:" %%a in ("%HERMES_REDIS_ADDR%") do (
    set "REDIS_HOST=%%a"
    set "REDIS_PORT=%%b"
)
if not defined REDIS_PORT set REDIS_PORT=6379

echo [check] Redis Stack at %HERMES_REDIS_ADDR%
powershell -NoProfile -Command ^
    "$r = Test-NetConnection -ComputerName '%REDIS_HOST%' -Port %REDIS_PORT% -WarningAction SilentlyContinue; if (-not $r.TcpTestSucceeded) { exit 1 }"

if errorlevel 1 (
    echo ERROR: cannot reach %HERMES_REDIS_ADDR%
    echo        ensure VM redis-stack container is running
    exit /b 1
)

echo OK: %HERMES_REDIS_ADDR% reachable
endlocal
exit /b 0
