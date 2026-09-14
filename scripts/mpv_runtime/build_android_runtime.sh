#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <abi> <mpv-android-builder-dir> <output-dir>" >&2
  exit 64
fi

ABI="$1"
BUILDER_DIR="$(cd "$2" && pwd)"
OUTPUT_DIR="$3"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK="$ROOT/third_party/mpv/android-runtime.lock.json"
PATCH="$ROOT/third_party/mpv/patches/android-media-kit-java-vm-v0.41.patch"

case "$ABI" in
  arm64-v8a) BUILDER_ARCH=arm64 ;;
  armeabi-v7a) BUILDER_ARCH=armv7l ;;
  x86) BUILDER_ARCH=x86 ;;
  x86_64) BUILDER_ARCH=x86_64 ;;
  *) echo "unsupported ABI: $ABI" >&2; exit 64 ;;
esac

: "${ANDROID_HOME:?ANDROID_HOME must point at the Android SDK}"

read_lock() {
  python3 - "$LOCK" "$1" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding='utf-8'))
value = obj
for part in sys.argv[2].split('.'):
    value = value[part]
print(value)
PY
}

TARGET_MPV_COMMIT="$(read_lock target.mpv_commit)"
BUILDER_COMMIT="$(read_lock builder.commit)"
DAV1D_COMMIT="$(read_lock source_pins.dav1d)"
FFMPEG_COMMIT="$(read_lock source_pins.ffmpeg)"
LIBASS_COMMIT="$(read_lock source_pins.libass)"
LIBPLACEBO_COMMIT="$(read_lock source_pins.libplacebo)"
BASE_RELEASE="$(read_lock media_kit_base.release)"
BASE_JAR="$(read_lock media_kit_base.jars.$ABI.name)"
BASE_SHA256="$(read_lock media_kit_base.jars.$ABI.sha256)"

actual_builder_commit="$(git -C "$BUILDER_DIR" rev-parse HEAD)"
if [[ "$actual_builder_commit" != "$BUILDER_COMMIT" ]]; then
  echo "builder commit mismatch: expected $BUILDER_COMMIT, got $actual_builder_commit" >&2
  exit 1
fi

pin_git() {
  local dir="$1"
  local commit="$2"
  git -C "$dir" fetch --depth=1 origin "$commit"
  git -C "$dir" checkout --detach "$commit"
  local actual
  actual="$(git -C "$dir" rev-parse HEAD)"
  [[ "$actual" == "$commit" ]] || {
    echo "pin mismatch for $dir: expected $commit, got $actual" >&2
    exit 1
  }
}

cd "$BUILDER_DIR/buildscripts"
mkdir -p sdk
if [[ ! -e sdk/android-sdk-linux ]]; then
  ln -s "$ANDROID_HOME" sdk/android-sdk-linux
fi

# The upstream builder is MIT licensed and pinned by commit. It provides the
# Android cross-toolchain plumbing; every moving source dependency used by the
# mpv 0.41 build is pinned again below before compilation.
IN_CI=1 ./download.sh

pin_git deps/dav1d "$DAV1D_COMMIT"
pin_git deps/ffmpeg "$FFMPEG_COMMIT"
pin_git deps/libass "$LIBASS_COMMIT"
pin_git deps/libplacebo "$LIBPLACEBO_COMMIT"
git -C deps/libplacebo submodule update --init --recursive
pin_git deps/mpv "$TARGET_MPV_COMMIT"

# Keep AnimeWitcher's current media_kit distribution characteristics: FFmpeg
# stays statically linked into libmpv and GPL-only features remain disabled.
# The pinned builder uses mbedTLS 3.x, so FFmpeg requires --enable-version3;
# this selects LGPLv3 while keeping GPL disabled. NDK r29 no longer ships
# target-prefixed binutils such as aarch64-linux-android-ar, so static FFmpeg
# must explicitly use the LLVM binutils that are present in the NDK toolchain.
python3 - <<'PY'
from pathlib import Path

ffmpeg = Path('scripts/ffmpeg.sh')
text = ffmpeg.read_text()
old = '--disable-static --enable-shared --enable-{gpl,version3}'
new = '--enable-static --disable-shared --disable-gpl --enable-version3'
if old not in text:
    raise SystemExit('unexpected mpv-android ffmpeg.sh: license/linkage anchor missing')
text = text.replace(old, new, 1)

tool_anchor = '--cross-prefix=$ndk_triple- --cc=$CC --pkg-config=pkg-config --nm=llvm-nm'
tool_replacement = (
    '--cross-prefix=$ndk_triple- --cc=$CC --pkg-config=pkg-config '
    '--nm=llvm-nm --ar=llvm-ar --ranlib=llvm-ranlib'
)
if tool_anchor not in text:
    raise SystemExit('unexpected mpv-android ffmpeg.sh: LLVM binutils anchor missing')
text = text.replace(tool_anchor, tool_replacement, 1)
ffmpeg.write_text(text)
updated = ffmpeg.read_text()
if '--enable-static --disable-shared --disable-gpl --enable-version3' not in updated:
    raise SystemExit('failed to configure FFmpeg for static LGPLv3 build')
if '--ar=llvm-ar --ranlib=llvm-ranlib' not in updated:
    raise SystemExit('failed to configure FFmpeg for NDK LLVM archive tools')

mpv = Path('scripts/mpv.sh')
text = mpv.read_text()
old = '-Dlibmpv=true -Dcplayer=false \\\n'
new = '-Dlibmpv=true -Dcplayer=false -Dgpl=false \\\n'
if old not in text:
    raise SystemExit('unexpected mpv-android mpv.sh: libmpv anchor missing')
mpv.write_text(text.replace(old, new, 1))
PY

git -C deps/mpv apply --check "$PATCH"
git -C deps/mpv apply "$PATCH"

./buildall.sh --arch "$BUILDER_ARCH" mpv

LIBMPV="$(find "prefix/${BUILDER_ARCH/armv7l/armv7l}" -type f -name libmpv.so -print -quit 2>/dev/null || true)"
if [[ -z "$LIBMPV" ]]; then
  # Prefix names currently match builder arches except the script still keeps
  # this fallback so a harmless layout change fails with a useful diagnostic.
  LIBMPV="$(find prefix -type f -name libmpv.so -print -quit)"
fi
[[ -n "$LIBMPV" && -f "$LIBMPV" ]] || {
  echo "built libmpv.so not found" >&2
  find prefix -maxdepth 4 -type f -print >&2 || true
  exit 1
}

STRIP="$(find sdk/android-ndk-r29/toolchains/llvm/prebuilt -type f -name llvm-strip -print -quit)"
[[ -x "$STRIP" ]] || { echo "llvm-strip not found" >&2; exit 1; }
"$STRIP" --strip-all "$LIBMPV"

mkdir -p "$OUTPUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BASE_PATH="$WORK/$BASE_JAR"
curl --fail --location --retry 4 \
  "https://github.com/media-kit/libmpv-android-video-build/releases/download/${BASE_RELEASE}/${BASE_JAR}" \
  --output "$BASE_PATH"
echo "$BASE_SHA256  $BASE_PATH" | sha256sum -c -

mkdir -p "$WORK/unpacked"
unzip -q "$BASE_PATH" -d "$WORK/unpacked"
NATIVE_DIR="$WORK/unpacked/lib/$ABI"
[[ -d "$NATIVE_DIR" ]] || {
  echo "media_kit base JAR is missing lib/$ABI" >&2
  find "$WORK/unpacked" -maxdepth 4 -type f -print >&2 || true
  exit 1
}
cp "$LIBMPV" "$NATIVE_DIR/libmpv.so"

OUT_JAR="$OUTPUT_DIR/$BASE_JAR"
(
  cd "$WORK/unpacked"
  zip -q -r "$OUT_JAR" .
)

# Verify the one produced ABI immediately; the workflow's aggregation job will
# run the strict all-four-ABI verifier before the bundle is accepted.
python3 - "$ROOT" "$ABI" "$OUT_JAR" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from scripts.mpv_runtime.verify_android_runtime import verify_jar
errors = verify_jar(sys.argv[2], Path(sys.argv[3]))
if errors:
    raise SystemExit('\n'.join(errors))
print(f"verified {sys.argv[2]} runtime: {sys.argv[3]}")
PY

sha256sum "$OUT_JAR" | tee "$OUTPUT_DIR/$BASE_JAR.sha256"
printf '%s\n' \
  "mpv=v0.41.0" \
  "mpv_commit=$TARGET_MPV_COMMIT" \
  "builder_commit=$BUILDER_COMMIT" \
  "ffmpeg_commit=$FFMPEG_COMMIT" \
  "ffmpeg_license=LGPLv3" \
  "libplacebo_commit=$LIBPLACEBO_COMMIT" \
  "abi=$ABI" > "$OUTPUT_DIR/$BASE_JAR.provenance.txt"