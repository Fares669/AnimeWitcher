#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <ios|macos> [--require-extracted]" >&2
  exit 64
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUB_CACHE_DIR="${PUB_CACHE:-$HOME/.pub-cache}"
args=(verify --platform "$1" --pub-cache "$PUB_CACHE_DIR" --repo-root "$ROOT")
if [[ ${2:-} == "--require-extracted" ]]; then
  args+=(--require-extracted)
elif [[ $# -eq 2 ]]; then
  echo "unknown option: $2" >&2
  exit 64
fi
exec python3 "$ROOT/scripts/mpv_runtime/prepare_apple_runtime.py" "${args[@]}"
