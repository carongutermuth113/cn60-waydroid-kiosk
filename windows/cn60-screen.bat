@echo off
setlocal
rem CN60 remote screen: see and control Android on the CN60 from Windows.
rem Needs: OpenSSH client (built into Windows 10/11) and scrcpy:
rem        winget install --id Genymobile.scrcpy
rem   (or unzip scrcpy from https://github.com/Genymobile/scrcpy/releases and put this file in that folder)
rem Usage: cn60-screen.bat [user@box-ip]

set "BOX=%~1"
if "%BOX%"=="" set /p "BOX=CN60 login (example: tv@192.168.1.158): "
if "%BOX%"=="" exit /b 1

set "ADB=adb"
set "SCRCPY=scrcpy"
if exist "%~dp0adb.exe" set "ADB=%~dp0adb.exe"
if exist "%~dp0scrcpy.exe" set "SCRCPY=%~dp0scrcpy.exe"

echo.
echo Asking the CN60 for Android's address (type the CN60 password if asked)...
set "WIP="
for /f "usebackq delims=" %%i in (`ssh %BOX% /usr/local/bin/cn60-remote --ip`) do set "WIP=%%i"
if "%WIP%"=="" set "WIP=192.168.240.112"
echo Android is at %WIP%.

echo.
echo Opening the SSH tunnel in a new window. Type the CN60 password there.
start "CN60 tunnel - close this window to disconnect" ssh -N -L 15555:%WIP%:5555 %BOX%
echo When the tunnel window is logged in (it stays blank), press any key here.
pause >nul

"%ADB%" connect 127.0.0.1:15555
echo If the TV shows "Allow USB debugging?", tick "Always allow" and press Allow.
"%SCRCPY%" -s 127.0.0.1:15555 --no-audio --window-title "CN60"
"%ADB%" disconnect 127.0.0.1:15555 >nul 2>&1
echo.
echo Done. Close the tunnel window to disconnect.
pause
