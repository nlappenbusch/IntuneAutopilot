@echo off
setlocal

:: Log-Datei im gleichen Verzeichnis wie die Batch
set "LOGFILE=%~dp0autopilot-log.txt"

echo ============================================== >> "%LOGFILE%"
echo [%DATE% %TIME%] Autopilot-Import gestartet... >> "%LOGFILE%"
echo ============================================== >> "%LOGFILE%"

echo Starte Autopilot-Import...
echo Log wird geschrieben nach: %LOGFILE%

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-AutopilotWithExternalAppConfig.ps1" 2>&1 | tee -Append "%LOGFILE%"

if %ERRORLEVEL% NEQ 0 (
    echo [%DATE% %TIME%] FEHLER: Script mit ErrorLevel %ERRORLEVEL% beendet >> "%LOGFILE%"
    echo FEHLER beim Autopilot-Import! Siehe Log: %LOGFILE%
    pause
    exit /b %ERRORLEVEL%
)

echo [%DATE% %TIME%] Skript erfolgreich abgeschlossen. >> "%LOGFILE%"
echo ============================================== >> "%LOGFILE%"
echo.
echo Autopilot-Import abgeschlossen!
echo Log: %LOGFILE%
echo.
pause
