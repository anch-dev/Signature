#!/usr/bin/env bash
# Linux equivalent of install.bat (NVIDIA GPU + CUDA driver required).
set -euo pipefail
cd "$(dirname "$0")"

ACESTEP_REPO=https://github.com/ace-step/ACE-Step-1.5.git
ACESTEP_COMMIT=ca1e85fe9430179831e6bc6be790c332190a3866
SIDESTEP_REPO=https://github.com/koda-dernet/Side-Step.git
SIDESTEP_COMMIT=fc800935a4b7f13a05103eafb7bacd623d7ed4f7

command -v git >/dev/null || { echo "Install git first"; exit 1; }
command -v uv >/dev/null || { curl -LsSf https://astral.sh/uv/install.sh | sh; export PATH="$HOME/.local/bin:$PATH"; }
mkdir -p runtime

checkout() {
  if [ ! -d "runtime/$1/.git" ]; then git clone --filter=blob:none "$2" "runtime/$1"; else git -C "runtime/$1" fetch -q origin; fi
  git -C "runtime/$1" -c advice.detachedHead=false checkout -q "$3"
}
checkout ACE-Step-1.5 "$ACESTEP_REPO" "$ACESTEP_COMMIT"
checkout Side-Step "$SIDESTEP_REPO" "$SIDESTEP_COMMIT"

(cd runtime/ACE-Step-1.5 && uv sync && uv run acestep-download)
(cd runtime/Side-Step && uv sync && uv run sidestep settings set checkpoint_dir "$PWD/../ACE-Step-1.5/checkpoints" >/dev/null 2>&1 || true)
(cd hub && uv sync)
echo "Done. Start with ./start.sh"
