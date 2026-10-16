@echo off
setlocal EnableDelayedExpansion
title Signature Hub - install
cd /d "%~dp0"

rem Pinned versions the Hub was written against. Re-run this file to update.
set "ACESTEP_REPO=https://github.com/ace-step/ACE-Step-1.5.git"
set "ACESTEP_COMMIT=ca1e85fe9430179831e6bc6be790c332190a3866"
set "SIDESTEP_REPO=https://github.com/koda-dernet/Side-Step.git"
set "SIDESTEP_COMMIT=fc800935a4b7f13a05103eafb7bacd623d7ed4f7"

echo.
echo  Signature Hub installer
echo  -----------------------
echo  Installs ACE-Step 1.5 (music engine + Studio GUI), Side-Step (style
echo  training) and the Hub. Needs about 25 GB of disk and an NVIDIA GPU.
echo.

where git >nul 2>&1 || (
  echo [X] git is not installed. Get it from https://git-scm.com/download/win and run this again.
  pause & exit /b 1
)
where nvidia-smi >nul 2>&1 && (
  for /f "delims=" %%g in ('nvidia-smi --query-gpu^=name^,memory.total --format^=csv^,noheader') do echo [OK] GPU: %%g
) || echo [!] nvidia-smi not found. Install the latest NVIDIA driver before generating or training.

where uv >nul 2>&1 || (
  echo [..] Installing uv ^(Python package manager^)
  powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex" || (echo [X] uv install failed & pause & exit /b 1)
  set "PATH=%USERPROFILE%\.local\bin;%PATH%"
)
for /f "delims=" %%v in ('uv --version') do echo [OK] %%v

if not exist runtime mkdir runtime

call :checkout "ACE-Step-1.5" "%ACESTEP_REPO%" "%ACESTEP_COMMIT%" || goto :fail
call :checkout "Side-Step" "%SIDESTEP_REPO%" "%SIDESTEP_COMMIT%" || goto :fail

echo.
echo [..] ACE-Step: installing Python + PyTorch (CUDA). This takes a while the first time.
pushd runtime\ACE-Step-1.5
uv sync || (popd & goto :fail)
echo [..] ACE-Step: downloading models (turbo DiT, 1.7B songwriter, VAE, text encoder, about 10 GB)
uv run acestep-download || (popd & goto :fail)
popd

echo.
echo [..] Side-Step: installing (shares PyTorch wheels from uv's cache)
pushd runtime\Side-Step
uv sync || (popd & goto :fail)
uv run sidestep settings set checkpoint_dir "%~dp0runtime\ACE-Step-1.5\checkpoints" >nul 2>&1
popd

echo.
echo [..] Hub
pushd hub
uv sync || (popd & goto :fail)
popd

echo.
echo [..] Allowing the phone to reach this PC (Windows Firewall, ports 8790 and 7860)
netsh advfirewall firewall show rule name="Signature Hub" >nul 2>&1
if errorlevel 1 (
  netsh advfirewall firewall add rule name="Signature Hub" dir=in action=allow protocol=TCP localport=8790,7860 profile=any remoteip=localsubnet,100.64.0.0/10 >nul 2>&1
  if errorlevel 1 (
    echo [!] Could not add the firewall rule - run install.bat as administrator, or click Allow when Windows asks on first start.
  ) else (
    echo [OK] Firewall rule added
  )
) else (
  echo [OK] Firewall rule already present
)

echo.
echo  Done. Start the Hub with start.bat
echo.
pause
exit /b 0

:checkout
set "NAME=%~1"
set "REPO=%~2"
set "COMMIT=%~3"
if not exist "runtime\%NAME%\.git" (
  echo [..] Cloning %NAME%
  git clone --filter=blob:none "%REPO%" "runtime\%NAME%" || exit /b 1
) else (
  echo [..] Updating %NAME%
  git -C "runtime\%NAME%" fetch --quiet origin || exit /b 1
)
git -C "runtime\%NAME%" -c advice.detachedHead=false checkout --quiet %COMMIT% || exit /b 1
echo [OK] %NAME% @ %COMMIT:~0,7%
exit /b 0

:fail
echo.
echo [X] Install failed. Scroll up for the error, fix it, and run install.bat again (it resumes).
pause
exit /b 1
