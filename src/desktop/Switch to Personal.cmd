@echo off
title Switch Claude to Personal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude-account-sync\claude-account-sync.ps1" switch personal
echo.
pause
