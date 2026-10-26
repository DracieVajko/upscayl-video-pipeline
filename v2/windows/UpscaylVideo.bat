@echo off
chcp 65001 >nul
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0UpscaylVideo.ps1" %*
set "CODE=%ERRORLEVEL%"
exit /b %CODE%
