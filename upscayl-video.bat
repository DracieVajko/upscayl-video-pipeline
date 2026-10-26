@echo off
chcp 65001 >nul
setlocal
where py >nul 2>nul
if %ERRORLEVEL%==0 (
    py -3 "%~dp0upscayl-video.py" %*
) else (
    python "%~dp0upscayl-video.py" %*
)
set "CODE=%ERRORLEVEL%"
exit /b %CODE%
