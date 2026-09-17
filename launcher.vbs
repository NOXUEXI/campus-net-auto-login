' CampusNetAutoLogin - hidden launcher
' Starts campus-login.ps1 in a fully hidden window (no console flash).
Option Explicit
Dim sh, root, cmd
Set sh = CreateObject("WScript.Shell")
root = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
cmd = "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & root & "campus-login.ps1"""
sh.Run cmd, 0, False
