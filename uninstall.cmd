@echo off
title Claude Account Sync uninstall
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\claude-account-sync.ps1" uninstall %*
echo.
pause
