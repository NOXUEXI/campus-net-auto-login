@echo off
cd /d "%~dp0"
title Campus Network Auto Login - Setup

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Password.ps1"
if errorlevel 1 goto end

echo.
choice /C YN /T 30 /D N /M "Run a login test now"
if errorlevel 2 goto end

echo.
echo  --- running login test ---
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0campus-login.ps1" -Force

echo.
echo  Run Check-Status.cmd to see the result and the log.
echo  The automatic login is now active: it runs at every Windows logon,
echo  on every unlock, and every 5 minutes in the background.

:end
echo.
pause
