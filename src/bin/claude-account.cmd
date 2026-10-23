@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude-account-sync\claude-account-sync.ps1" %*
exit /b %ERRORLEVEL%
