#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <ios|macos> <runtime.tar.gz> <sha256> <overlay-version>" >&2
  exit 64
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUB_CACHE_DIR="${PUB_CACHE:-$HOME/.pub-cache}"
exec python3 "$ROOT/scripts/mpv_runtime/prepare_apple_runtime.py" prepare \
  --platform "$1" \
  --archive "$2" \
  --sha256 "$3" \
  --overlay-version "$4" \
  --pub-cache "$PUB_CACHE_DIR" \
  --repo-root "$ROOT"
