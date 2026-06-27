@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
pushd "%SCRIPT_DIR%.." >nul
set "TOOLS_DIR=%CD%\Eion-tools"
popd >nul

call "%SCRIPT_DIR%memory-env.bat"
call "%SCRIPT_DIR%check-redis-vm.bat"
if errorlevel 1 exit /b 1

set HERMES_EMBEDDING_DIM=64
set HERMES_MEMORY_INDEX=hermes_memory_test
set HERMES_MEMORY_KEY_PREFIX=hermes_mem_test:

pushd "%TOOLS_DIR%"
echo integration test redis=%HERMES_REDIS_ADDR%
go test -tags integration ./internal/memory/... -run TestStoreAndSearch_Integration -v -count=1
set "TEST_RC=!ERRORLEVEL!"
popd
exit /b !TEST_RC!
