@echo off
REM start-redis.bat - ??? Redis??? Docker??????
REM ???: scrtps\setup-redis.ps1
REM ???: memory ????????VM Redis Stack (192.168.59.129)??? memory-env.bat
REM       ???????Redis ??RediSearch????????Redis Stack

setlocal

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "REDIS_DIR=%ROOT_DIR%\bin\env\redis"
set "RUN_DIR=%ROOT_DIR%\bin\run\redis"
set "REDIS_SVC=%REDIS_DIR%\RedisService.exe"

if not exist "%REDIS_SVC%" (
    echo ERROR: Redis not installed. Run: powershell -ExecutionPolicy Bypass -File scrtps\setup-redis.ps1
    exit /b 1
)

if not exist "%RUN_DIR%" mkdir "%RUN_DIR%"

echo ==> Starting local Redis on 127.0.0.1:6379
echo    binary = %REDIS_SVC%
echo    data   = %RUN_DIR%
echo    (Ctrl+C to stop)
echo.

"%REDIS_SVC%" run --foreground --port 6379 --dir "%RUN_DIR%"

endlocal
