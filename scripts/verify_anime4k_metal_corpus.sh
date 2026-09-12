#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/anime4k-metal-corpus.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ARCHIVE="$TMP/Anime4K_v4.0.zip"
EXTRACTED="$TMP/extracted"
CORPUS="$TMP/corpus"
GENERATED="$TMP/generated-metal"
AIR="$TMP/air"
mkdir -p "$EXTRACTED" "$CORPUS" "$GENERATED" "$AIR"

URL="https://github.com/bloc97/Anime4K/releases/download/v4.0.1/Anime4K_v4.0.zip"
echo "Downloading pinned Anime4K v4.0.1 corpus..."
curl --fail --location --silent --show-error --retry 3 --retry-all-errors \
  "$URL" --output "$ARCHIVE"
unzip -q "$ARCHIVE" -d "$EXTRACTED"

# Treat the Dart production manifest as the single source of truth for which
# shader bytes AnimeWitcher supports. Validate the official release against the
# same byte sizes and Git blob ids that the runtime downloader enforces.
#
# Report every mismatch in one run. Besides being better diagnostics, this is
# important because GitHub release assets can legitimately differ byte-for-byte
# from the Git tree that shares a tag.
python3 - \
  "$ROOT/lib/features/player/data/anime4k_download.dart" \
  "$EXTRACTED" \
  "$CORPUS" <<'PY'
import hashlib
import pathlib
import re
import shutil
import sys

manifest_path = pathlib.Path(sys.argv[1])
extracted = pathlib.Path(sys.argv[2])
corpus = pathlib.Path(sys.argv[3])
text = manifest_path.read_text(encoding="utf-8")
pattern = re.compile(
    r"'(?P<name>Anime4K_[^']+\.glsl)'\s*:\s*Anime4kExpectedShader\(\s*"
    r"size:\s*(?P<size>\d+)\s*,\s*"
    r"gitBlobSha1:\s*'(?P<sha>[0-9a-f]{40})'",
    re.S,
)
entries = [
    (m.group("name"), int(m.group("size")), m.group("sha"))
    for m in pattern.finditer(text)
]
if len(entries) != 23 or len({name.lower() for name, _, _ in entries}) != 23:
    raise SystemExit(
        f"expected exactly 23 unique pinned shaders, found {len(entries)}"
    )

by_basename = {}
for path in extracted.rglob("*"):
    if path.is_file() and path.suffix.lower() == ".glsl":
        by_basename.setdefault(path.name.lower(), []).append(path)

errors = []
for name, expected_size, expected_blob in entries:
    matches = by_basename.get(name.lower(), [])
    if len(matches) != 1:
        errors.append(f"{name}: expected one release file, found {len(matches)}")
        continue

    path = matches[0]
    data = path.read_bytes()
    actual_blob = hashlib.sha1(
        f"blob {len(data)}\0".encode("utf-8") + data
    ).hexdigest()
    if len(data) != expected_size or actual_blob != expected_blob:
        errors.append(
            f"{name}: pinned integrity mismatch "
            f"size={len(data)}/{expected_size} "
            f"blob={actual_blob}/{expected_blob}\n"
            f"  releaseAsset: Anime4kExpectedShader("
            f"size: {len(data)}, gitBlobSha1: '{actual_blob}')"
        )
        continue

    shutil.copy2(path, corpus / name)

if errors:
    print(
        "Anime4K v4.0.1 release asset differs from the pinned manifest:",
        file=sys.stderr,
    )
    for error in errors:
        print(f"- {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"Verified {len(entries)} pinned Anime4K v4.0.1 shader files")
PY

SWIFT_TEST="$TMP/anime4k_metal_shader_tests"
swiftc \
  "$ROOT/native/anime4k_metal/Anime4KMetalShader.swift" \
  "$ROOT/native/anime4k_metal/Anime4KMetalShaderTests.swift" \
  -o "$SWIFT_TEST"

PRECISION_TEST="$TMP/anime4k_metal_precision_tests"
swiftc \
  -parse-as-library \
  "$ROOT/native/anime4k_metal/Anime4KMetalPrecisionTests.swift" \
  -o "$PRECISION_TEST"
"$PRECISION_TEST"

# macOS still ships Bash 3.2, which has no `mapfile`. Populate arrays with a
# portable read loop so the exact same verifier works on Apple CI and locally.
SHADERS=()
while IFS= read -r file; do
  SHADERS+=("$file")
done < <(find "$CORPUS" -type f -name '*.glsl' -print | sort)

if [[ "${#SHADERS[@]}" -ne 23 ]]; then
  echo "Expected 23 corpus shaders, found ${#SHADERS[@]}" >&2
  exit 1
fi
"$SWIFT_TEST" "$GENERATED" "${SHADERS[@]}"

METAL_SOURCES=()
while IFS= read -r file; do
  METAL_SOURCES+=("$file")
done < <(find "$GENERATED" -type f -name '*.metal' -print | sort)

if [[ "${#METAL_SOURCES[@]}" -eq 0 ]]; then
  echo "Translator emitted no Metal sources" >&2
  exit 1
fi

echo "Compiling ${#METAL_SOURCES[@]} generated Metal passes..."
for source in "${METAL_SOURCES[@]}"; do
  output="$AIR/$(basename "${source%.metal}").air"
  xcrun -sdk macosx metal -c "$source" -o "$output"
done

echo "Anime4K v4.0.1 Metal corpus verification: PASS (${#METAL_SOURCES[@]} passes)"
