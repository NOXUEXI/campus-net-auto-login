@echo off
cd /d "%~dp0"
chcp 65001 >nul
title Campus Network Auto Login - Status

echo.
echo  ===== portal status =====
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0campus-login.ps1" -Status

echo.
echo  ===== scheduled task =====
powershell.exe -NoLogo -NoProfile -Command "$t=Get-ScheduledTask -TaskName 'CampusNetAutoLogin' -ErrorAction SilentlyContinue; if($t){ 'TaskName : '+$t.TaskName; 'State    : '+$t.State } else { 'TASK NOT REGISTERED' }; $i=Get-ScheduledTaskInfo -TaskName 'CampusNetAutoLogin' -ErrorAction SilentlyContinue; if($i){ 'LastRun  : '+$i.LastRunTime; 'LastCode : '+$i.LastTaskResult; 'NextRun  : '+$i.NextRunTime }"

echo.
echo  ===== last log lines =====
powershell.exe -NoLogo -NoProfile -Command "Get-Content -LiteralPath '%~dp0login.log' -Tail 15 -ErrorAction SilentlyContinue"

echo.
pause
