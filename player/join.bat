@echo off
rem Double-click to join. Runs join.ps1 without changing the PowerShell execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0join.ps1" %*
if errorlevel 1 pause
