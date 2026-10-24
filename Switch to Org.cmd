@echo off
title Switch Claude to Org
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\claude-account-sync.ps1" switch org
echo.
pause
