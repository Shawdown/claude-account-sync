@echo off
setlocal
set "CLAUDE_CONFIG_DIR=%USERPROFILE%\.claude"
call claude %*
exit /b %ERRORLEVEL%
