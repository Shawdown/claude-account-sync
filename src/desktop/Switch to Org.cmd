@echo off
title Switch Claude to Org
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude-account-sync\claude-account-sync.ps1" switch org
echo.
pause
