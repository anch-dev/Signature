@echo off
setlocal EnableDelayedExpansion
title Signature Hub - YuE2 (experimental)
cd /d "%~dp0"

rem audio.cpp runs YuE2 on the GPU. Pinned release; re-run to update.
set "AUDIOCPP_VER=v0.9.2"
set "AUDIOCPP_URL=https://github.com/0xShug0/audio.cpp/releases/download/%AUDIOCPP_VER%"
set "AUDIOCPP_BIN=audio-%AUDIOCPP_VER%-bin-windows-x64-cuda12.4.zip"
set "AUDIOCPP_RT=audio-%AUDIOCPP_VER%-cudart-windows-x64-cuda12.4.zip"
set "YUE2_REPO=audio-cpp/Yue2-3B-GGUF"
rem q8_0 fits a 12 GB card (peak ~9 GB). Use q4_0 on 8 GB cards: install-yue2.bat q4
set "YUE2_MAIN=yue2-3b-q8_0.gguf"
if /i "%~1"=="q4" set "YUE2_MAIN=yue2-3b-q4_0.gguf"

echo.
echo  YuE2 for Signature Hub (experimental)
echo  -------------------------------------
echo  Downloads audio.cpp %AUDIOCPP_VER% (CUDA 12.4) and YuE2-3B (%YUE2_MAIN%, VAE, sidecars).
echo  About 5-7 GB. YuE2-3B is licensed CC BY-NC 4.0: non-commercial use only.
echo.

if not exist runtime mkdir runtime
if not exist runtime\models mkdir runtime\models

echo [..] audio.cpp
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $d='runtime\audio.cpp'; if (Test-Path $d) { Remove-Item -Recurse -Force $d };" ^
  "New-Item -ItemType Directory -Force $d | Out-Null;" ^
  "foreach ($f in @('%AUDIOCPP_BIN%','%AUDIOCPP_RT%')) { Write-Host \"     $f\"; Invoke-WebRequest -Uri ('%AUDIOCPP_URL%/'+$f) -OutFile \"$env:TEMP\$f\"; Expand-Archive -Force \"$env:TEMP\$f\" $d; Remove-Item \"$env:TEMP\$f\" };" ^
  "$cli = Get-ChildItem -Recurse $d -Filter audiocpp_cli.exe | Select-Object -First 1;" ^
  "if (-not $cli) { throw 'audiocpp_cli.exe not found in the release' };" ^
  "Get-ChildItem -Recurse $d -Filter *.dll | Where-Object { $_.DirectoryName -ne $cli.DirectoryName } | Copy-Item -Destination $cli.DirectoryName -Force;" ^
  "Write-Host \"[OK] $($cli.FullName)\"" || goto :fail

echo [..] YuE2 model files from Hugging Face (%YUE2_REPO%)
where uv >nul 2>&1 || (echo [X] uv not found - run install.bat first & goto :fail)
uvx --from huggingface_hub hf download %YUE2_REPO% --include "%YUE2_MAIN%" --include "yue2-vae-f16.gguf" --include "sidecars/*" --local-dir runtime\models\Yue2-3B-GGUF || goto :fail

echo.
echo  Done. Restart the Hub (start.bat); YuE2 shows up as an engine in the app.
echo.
pause
exit /b 0

:fail
echo.
echo [X] YuE2 install failed. Check your connection and run install-yue2.bat again.
pause
exit /b 1
