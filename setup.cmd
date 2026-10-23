@echo off
title Claude Account Sync setup
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\claude-account-sync.ps1" setup %*
echo.
pause
