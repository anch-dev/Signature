@echo off
title Signature Hub
cd /d "%~dp0"
where uv >nul 2>&1 || set "PATH=%USERPROFILE%\.local\bin;%PATH%"
if not exist hub\.venv (
  echo Run install.bat first.
  pause & exit /b 1
)
uv run --project hub signature-hub
pause
