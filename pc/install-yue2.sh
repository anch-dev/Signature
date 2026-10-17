#!/usr/bin/env bash
# Linux equivalent of install-yue2.bat: audio.cpp (CUDA) + YuE2-3B GGUF. Experimental.
# YuE2-3B is licensed CC BY-NC 4.0 (non-commercial). Usage: ./install-yue2.sh [q4]
set -euo pipefail
cd "$(dirname "$0")"
VER=v0.9.2
URL=https://github.com/0xShug0/audio.cpp/releases/download/$VER
MAIN=yue2-3b-q8_0.gguf; [ "${1:-}" = "q4" ] && MAIN=yue2-3b-q4_0.gguf
mkdir -p runtime/models
rm -rf runtime/audio.cpp && mkdir -p runtime/audio.cpp
for f in audio-$VER-bin-ubuntu-x64-cuda12.8-colab.tar.gz audio-$VER-cudart-ubuntu-x64-cuda12.8.tar.gz; do
  echo "[..] $f"; curl -fL "$URL/$f" | tar -xz -C runtime/audio.cpp
done
cli=$(find runtime/audio.cpp -name audiocpp_cli -type f | head -1)
[ -n "$cli" ] || { echo "[X] audiocpp_cli not found"; exit 1; }
chmod +x "$cli"; echo "[OK] $cli"
command -v uv >/dev/null || { echo "[X] uv not found - run install.sh first"; exit 1; }
uvx --from huggingface_hub hf download audio-cpp/Yue2-3B-GGUF --include "$MAIN" --include yue2-vae-f16.gguf \
  --include "sidecars/*" --local-dir runtime/models/Yue2-3B-GGUF
echo "Done. Restart the Hub; YuE2 shows up as an engine in the app."
