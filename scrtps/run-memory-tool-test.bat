@echo off
REM run-memory-tool-test.bat - Go memory store/search 联调
REM   默认: VM Redis Stack integration 测试
REM   本地 dev: run-memory-tool-test.bat dev

set "SCRIPT_DIR=%~dp0"

if /I "%~1"=="dev" (
    setlocal EnableDelayedExpansion
    pushd "%SCRIPT_DIR%..\Eion-tools"
    echo [memory] dev backend test - no Redis
    set HERMES_MEMORY_BACKEND=dev
    set HERMES_MEMORY_MOCK_EMBED=1
    set HERMES_EMBEDDING_DIM=64
    go test ./internal/memory/... -run TestDevBackend -v -count=1
    set "TEST_RC=!ERRORLEVEL!"
    popd
    exit /b !TEST_RC!
)

call "%SCRIPT_DIR%run-redis-integration-test.bat"
