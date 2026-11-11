@echo off
setlocal
if "%~1"=="" (
    powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0LayerExplode.ps1"
) else (
    powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File "%~dp0LayerExplode.ps1" -InputDir "%~1"
)
set "RESULT=%ERRORLEVEL%"
echo.
pause
exit /b %RESULT%
