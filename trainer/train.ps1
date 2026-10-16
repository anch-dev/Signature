# train.ps1 - turn your songs into a style adapter for the Signature iPhone app.
#
#     powershell -ExecutionPolicy Bypass -File .\train.ps1 -Songs D:\my_songs -Trigger anchstyle
#
# Steps (each one is skipped if its output already exists, so you can re-run
# after fixing lyrics or after a crash):
#   1. Write lyrics/caption sidecars   (Whisper + Demucs, prep_dataset.py)
#   2. Detect BPM / key / time sig     (Side-Step audio-analyze, offline)
#   3. Build dataset.json              (Side-Step dataset, adds your trigger word)
#   4. Preprocess to tensors           (Side-Step preprocess, turbo model)
#   5. Train a LoRA                    (12 GB profile: rank 32, AdamW8bit, encoder offload)
#   6. Export one .safetensors file    (copy this to the phone)
#
# Settings below follow Side-Step's built-in vram_12gb preset, plus 60 s random
# chunking, which keeps full-length songs inside 12 GB.

param(
    [Parameter(Mandatory = $true)][string]$Songs,
    [string]$Trigger = "mystyle",
    [int]$Epochs = 800,
    [int]$Rank = 32,
    [string]$Language = "",
    [switch]$SkipLyrics,
    [switch]$Fresh
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$side = Join-Path $root "Side-Step"
$Songs = (Resolve-Path $Songs).Path
$work = Join-Path $root "work\$Trigger"
$tensors = Join-Path $work "tensors"
$out = Join-Path $work "lora"
$adapter = Join-Path $root "$Trigger.safetensors"

function Step($n, $m) { Write-Host "`n[$n/6] $m" -ForegroundColor Cyan }
function SS { & uv run sidestep @args; if ($LASTEXITCODE -ne 0) { throw "sidestep $($args[0]) failed" } }

if (-not (Test-Path $side)) { throw "Side-Step not found at $side. Run setup.ps1 first." }
if ($Trigger -notmatch '^[a-z0-9_]+$') { throw "Use a lowercase trigger word with no spaces, e.g. anchstyle" }
if ($Fresh -and (Test-Path $work)) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force -Path $work | Out-Null

$count = (Get-ChildItem -Recurse -File $Songs | Where-Object { $_.Extension -match '\.(wav|mp3|flac|ogg|opus|m4a)$' }).Count
if ($count -lt 8) { Write-Warning "Only $count songs found. 10-20+ gives a much more reliable style." }

Push-Location $side
try {
    Step 1 "Writing lyrics and captions"
    if ($SkipLyrics) {
        Write-Host "Skipped (-SkipLyrics)."
    } else {
        $prepArgs = @("run", "--with", "openai-whisper", "python", (Join-Path $here "prep_dataset.py"), $Songs)
        if ($Language) { $prepArgs += @("--language", $Language) }
        & uv @prepArgs
        if ($LASTEXITCODE -ne 0) { throw "prep_dataset.py failed" }
        Write-Host "`nCheck the .txt files next to your songs now if you want to fix lyrics." -ForegroundColor Yellow
        Read-Host "Press Enter to continue training"
    }

    Step 2 "Detecting BPM, key and time signature"
    SS audio-analyze --input $Songs --mode mid --policy fill_missing

    Step 3 "Building dataset.json with trigger word '$Trigger'"
    $json = Join-Path $Songs "dataset.json"
    SS dataset --input $Songs --tag $Trigger --tag-position prepend --name $Trigger --output $json

    Step 4 "Preprocessing audio to tensors (turbo)"
    if (Test-Path (Join-Path $tensors "manifest.json")) {
        Write-Host "Tensors already exist, skipping. Use -Fresh after changing songs or lyrics."
    } else {
        SS preprocess --audio-dir $Songs --dataset-json $json --output $tensors --model turbo
    }

    Step 5 "Training ($Epochs epochs, rank $Rank). Watch progress with: uv run tensorboard --logdir `"$out\runs`""
    SS train `
        --model turbo `
        --dataset-dir $tensors `
        --output-dir $out `
        --adapter lora --rank $Rank --alpha ($Rank * 2) --dropout 0.1 `
        --target-mlp --attention-type both `
        --lr 3e-4 --batch-size 1 --gradient-accumulation 4 --warmup-steps 100 `
        --epochs $Epochs --optimizer-type adamw8bit --scheduler-type cosine `
        --gradient-checkpointing --offload-encoder `
        --chunk-duration 60 `
        --save-every 50 --save-best

    Step 6 "Exporting adapter"
    $final = Join-Path $out "final"
    if (-not (Test-Path $final)) { throw "No final adapter at $final" }
    SS export $final --output $adapter --target native
} finally {
    Pop-Location
}

Write-Host "`nAdapter ready: $adapter" -ForegroundColor Green
Write-Host "AirDrop or copy it to your iPhone, open it with Signature, and put '$Trigger' at the start of your prompt."
