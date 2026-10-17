#!/usr/bin/env bash
# Clone the pinned acestep.cpp (+ ggml submodule) into ios/vendor and apply
# Signature's engine patches. Shared by the iOS and Android builds.
set -euo pipefail

ACESTEP_REPO="https://github.com/ServeurpersoCom/acestep.cpp.git"
ACESTEP_COMMIT="de858d8e1a94f0e1939cf9bdd8ff7d9631953077"   # tested with this bridge

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # ios/
VENDOR="$HERE/vendor/acestep.cpp"

if [ ! -f "$VENDOR/src/pipeline-synth.h" ]; then
    echo "==> Fetching acestep.cpp @ ${ACESTEP_COMMIT:0:7}"
    rm -rf "$VENDOR"
    mkdir -p "$VENDOR"
    git -C "$VENDOR" init -q
    git -C "$VENDOR" remote add origin "$ACESTEP_REPO"
    git -C "$VENDOR" fetch -q --depth 1 origin "$ACESTEP_COMMIT"
    git -C "$VENDOR" checkout -q FETCH_HEAD
    git -C "$VENDOR" submodule update -q --init --depth 1 ggml
fi

echo "==> Applying Signature engine patches"
for p in "$HERE"/engine/patches/*.patch; do
    if git -C "$VENDOR" apply --reverse --check "$p" 2>/dev/null; then
        echo "    already applied: $(basename "$p")"
    else
        git -C "$VENDOR" apply "$p"
        echo "    applied: $(basename "$p")"
    fi
done
