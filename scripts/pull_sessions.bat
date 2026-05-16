@echo off
REM Pull all GS Camera session folders off the connected Android phone
REM into ./captures/ for postshot ingestion.

setlocal enabledelayedexpansion

set "ADB=C:\Users\kodua\AppData\Local\Android\Sdk\platform-tools\adb.exe"
set "PKG=com.gscamera.gs_camera"
set "SRC=/storage/emulated/0/Android/data/%PKG%/files/GSCamera"
set "DEST=%~dp0..\captures"

"%ADB%" devices | findstr /R "device$" >nul
if errorlevel 1 (
    echo [!] No device connected.
    exit /b 1
)

if not exist "%DEST%" mkdir "%DEST%"

echo [*] Pulling session folders from %SRC% to %DEST%
"%ADB%" pull "%SRC%" "%DEST%"

echo.
echo [*] Done. Sessions are at:
echo     %DEST%
echo Drop one into postshot as an image sequence.
