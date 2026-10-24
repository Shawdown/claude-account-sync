@echo off
title Switch Claude to Personal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\claude-account-sync.ps1" switch personal
echo.
pause
