# setup.ps1 - one-time install of the training tools on Windows (RTX 3080 Ti).
#
# Run from PowerShell in the folder that contains this script:
#     powershell -ExecutionPolicy Bypass -File .\setup.ps1
#
# What it does:
#   1. Clones Side-Step (the ACE-Step 1.5 fine-tuning tool) next to this folder.
#   2. Runs Side-Step's own Windows installer, which installs uv, Python 3.11,
#      PyTorch with CUDA, and offers to download the ACE-Step checkpoints.
#      Say YES to the turbo checkpoint download - the phone app runs turbo,
#      so the adapter must be trained on turbo too.
#   3. Points Side-Step's settings at that checkpoint folder.

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$side = Join-Path $root "Side-Step"

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

Step "Checking for git and an NVIDIA GPU"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is not installed. Get it from https://git-scm.com/download/win and re-run."
}
try {
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
} catch {
    throw "nvidia-smi not found. Install the latest NVIDIA Game Ready or Studio driver first."
}

if (-not (Test-Path $side)) {
    Step "Cloning Side-Step into $side"
    git clone https://github.com/koda-dernet/Side-Step.git $side
} else {
    Step "Side-Step already present, pulling updates"
    git -C $side pull --ff-only
}

Step "Running Side-Step's installer (answer YES to the turbo checkpoint download)"
Push-Location $side
try {
    & powershell -ExecutionPolicy Bypass -File .\install_windows.ps1
} finally {
    Pop-Location
}

$ckpt = Join-Path $side "checkpoints"
if (-not (Test-Path (Join-Path $ckpt "acestep-v15-turbo"))) {
    Write-Warning "Turbo checkpoint not found in $ckpt. Downloading it now (about 5 GB)."
    Push-Location $side
    uv run hf download ACE-Step/Ace-Step1.5 --local-dir $ckpt --exclude "acestep-5Hz-lm-*/*"
    Pop-Location
}

Step "Saving checkpoint location in Side-Step settings"
Push-Location $side
uv run sidestep settings set checkpoint_dir $ckpt
Pop-Location

Write-Host "`nSetup complete." -ForegroundColor Green
Write-Host "Next: put your songs in a folder with vocals\ and instrumentals\ subfolders, then run .\train.ps1 -Songs <that folder>"
