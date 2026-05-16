@echo off
REM Quick installer + launcher for GS Camera.
REM Connect your Android phone via USB with USB Debugging enabled, then
REM run this script. It installs the latest debug APK, launches the app,
REM and streams logcat output filtered to our app's tag.

setlocal enabledelayedexpansion

set "APK=%~dp0..\app\build\app\outputs\flutter-apk\app-debug.apk"
set "ADB=C:\Users\kodua\AppData\Local\Android\Sdk\platform-tools\adb.exe"
set "PKG=com.gscamera.gs_camera"

if not exist "%APK%" (
    echo [!] APK not found at %APK%
    echo     Run: flutter build apk --debug
    exit /b 1
)

"%ADB%" devices | findstr /R "device$" >nul
if errorlevel 1 (
    echo [!] No device connected.
    echo     Plug in the phone, enable USB Debugging in Developer Options,
    echo     and accept the RSA prompt on the phone.
    exit /b 1
)

echo [*] Installing APK...
"%ADB%" install -r "%APK%" || exit /b 1

echo [*] Launching app...
"%ADB%" shell am start -n %PKG%/%PKG%.MainActivity

echo [*] Streaming logcat (Ctrl-C to stop)...
"%ADB%" logcat -v color GsCameraSession:V GsCameraPlugin:V flutter:V *:E
