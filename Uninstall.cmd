@echo off
cd /d "%~dp0"
title Campus Network Auto Login - Uninstall

echo.
echo  This will remove the automatic campus network login.
echo.

choice /C YN /T 30 /D N /M "Remove the scheduled task"
if errorlevel 2 goto end
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Unregister-ScheduledTask -TaskName 'CampusNetAutoLogin' -Confirm:$false -ErrorAction SilentlyContinue; Write-Host '  scheduled task removed'"

echo.
choice /C YN /T 30 /D N /M "Also delete the stored password (cred.dat)"
if errorlevel 2 goto end
if exist "%~dp0cred.dat" del /f /q "%~dp0cred.dat"
echo   cred.dat deleted

:end
echo.
echo  To remove everything, just delete this folder:
echo  %~dp0
echo.
pause
