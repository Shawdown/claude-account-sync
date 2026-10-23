@echo off
setlocal
set "CLAUDE_CONFIG_DIR=%USERPROFILE%\.claude-org"
call claude %*
exit /b %ERRORLEVEL%
