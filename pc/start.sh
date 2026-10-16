#!/usr/bin/env bash
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
exec uv run --project hub signature-hub
