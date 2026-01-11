@echo off
setlocal EnableExtensions

set "SCRIPT=%~dp0Run-AutopilotWithExternalAppConfig.ps1"
set "LOGDIR=%~dp0logs"
set "LOGFILE=%LOGDIR%\autopilot-log.txt"

if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1

echo ==============================================
echo Starte Autopilot-Import...
echo Log: %LOGFILE%
echo ==============================================

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$log='%LOGFILE%';" ^
  "Add-Content $log '==============================================';" ^
  "Add-Content $log ('['+(Get-Date)+'] Autopilot-Import gestartet');" ^
  "try {" ^
  "  & '%SCRIPT%' 2>&1 | Tee-Object -FilePath $log -Append;" ^
  "  exit $LASTEXITCODE" ^
  "} catch {" ^
  "  $_ | Out-String | Tee-Object -FilePath $log -Append;" ^
  "  exit 1" ^
  "}"

set "PSEXIT=%ERRORLEVEL%"

if not "%PSEXIT%"=="0" (
  echo.
  echo FEHLER: Script mit ExitCode %PSEXIT% beendet
  echo Siehe Log: %LOGFILE%
  pause
  exit /b %PSEXIT%
)

echo.
echo Autopilot-Import erfolgreich abgeschlossen
echo Log: %LOGFILE%
echo.
pause
exit /b 0
