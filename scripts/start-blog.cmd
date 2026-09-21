@echo off
REM Shirone blog launcher - thin wrapper so the script can be double-clicked.
REM All arguments are forwarded to start-blog.ps1 (e.g. -ContentDir, -Port, -Watch).
setlocal
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-blog.ps1" %*
exit /b %errorlevel%
