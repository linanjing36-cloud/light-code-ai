@echo off
REM start-tools.bat - Launch Eion-tools server standalone (debug only) - Windows
REM
REM Eion-tools server is normally spawned by Erlang bridge_manager via
REM erlang:open_port (bridge_manager.erl:101). This script is for debug only:
REM   - Run eion-tools-server.exe to observe zap log on stderr
REM   - Pipe a protobuf test frame to verify dispatch logic
REM   - Verify the compiled binary can boot
REM
REM Usage:
REM   bin\start-tools.bat                        REM foreground (Ctrl+C to exit, zap log to stderr)
REM   bin\start-tools.bat < test_frame.bin       REM feed a test frame (4-byte BE len + protobuf AgentRequest)
REM
REM Frame format (aligned with Eion-tools/cmd/server/main.go readFrame/writeFrame):
REM   Request : [4-byte big-endian length][protobuf AgentRequest payload]
REM   Response: [4-byte big-endian length][protobuf AgentResponse payload]
REM
REM Notes:
REM   1. Without an Erlang peer sending frames, the process blocks on stdin.
REM      This is expected, NOT a deadlock.
REM   2. Production uses bridge_manager open_port; do NOT use this script in prod.
REM   3. After feeding test frames, EOF makes the process exit cleanly
REM      (main.go runFramingLoop returns nil on io.EOF).

setlocal

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%.."
set "EION_BIN_DIR=%ROOT_DIR%\bin\eion_bin"
set "EION_EXE=%EION_BIN_DIR%\eion-tools-server.exe"

if not exist "%EION_EXE%" (
    echo ERROR: Eion-tools server not found, please run: make agent
    echo    expected: %EION_EXE%
    exit /b 1
)

echo ==> Starting Eion-tools server (debug mode)
echo    binary  = %EION_EXE%
echo    protocol= stdin/stdout, 4-byte BE length prefix + protobuf frame loop
echo    (Ctrl+C to exit / blocks on stdin if no Erlang peer, that is normal)
echo    (pipe a frame: bin\start-tools.bat ^< test_frame.bin)
echo.

"%EION_EXE%"

REM Show exit code after the process returns (for debugging)
echo.
echo ==> Eion-tools server exited, exit code = %ERRORLEVEL%

endlocal
