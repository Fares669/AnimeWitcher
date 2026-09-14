#!/usr/bin/env bash
set -euo pipefail

readonly MEDIA_KIT_VIDEO_VERSION="2.0.1"
readonly MEDIA_KIT_RUNTIME_VERSION="1.1.4"
readonly PLATFORM="${1:-ios}"

case "$PLATFORM" in
  ios)
    readonly RUNTIME_PACKAGE="media_kit_libs_ios_video"
    ;;
  macos)
    readonly RUNTIME_PACKAGE="media_kit_libs_macos_video"
    ;;
  *)
    echo "media_kit Darwin header preparation failed: unsupported platform $PLATFORM" >&2
    exit 64
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pub_cache="${PUB_CACHE:-$HOME/.pub-cache}"
integration="$repo_root/third_party/mpv/integration.json"
lock="$repo_root/third_party/mpv/darwin-runtime.lock.json"

fail() {
  echo "media_kit Darwin header preparation failed: $*" >&2
  exit 1
}

[[ -f "$integration" ]] || fail "mpv integration contract is missing"
[[ -f "$lock" ]] || fail "Darwin runtime lock is missing"

mapfile -t contract < <(python3 - "$integration" "$lock" "$PLATFORM" <<'PY'
import json
import sys

integration = json.load(open(sys.argv[1], encoding="utf-8"))
lock = json.load(open(sys.argv[2], encoding="utf-8"))
platform = sys.argv[3]
tag = integration["target"]["tag"]
if tag != lock["target"]["mpv_tag"]:
    raise SystemExit("integration target and Darwin runtime lock disagree")
artifact = lock["artifacts"][platform]
print(tag)
for name in ("client.h", "render.h", "render_gl.h", "stream_cb.h"):
    print(f"{name} {integration['target']['headers'][name]}")
print(artifact["overlay_version"])
print(artifact["sha256"])
print(artifact["url"])
PY
)
[[ ${#contract[@]} -eq 8 ]] || fail "unable to read target/header/runtime contract"
readonly MPV_VERSION="${contract[0]}"
readonly MPV_OVERLAY_VERSION="${contract[5]}"
readonly MPV_RUNTIME_SHA256="${contract[6]}"
readonly MPV_RUNTIME_URL="${contract[7]}"

shopt -s nullglob
video_candidates=("$pub_cache"/hosted/*/media_kit_video-"$MEDIA_KIT_VIDEO_VERSION")
[[ ${#video_candidates[@]} -eq 1 ]] || \
  fail "expected one resolved media_kit_video $MEDIA_KIT_VIDEO_VERSION package, found ${#video_candidates[@]}"
package_dir="${video_candidates[0]}"

runtime_candidates=("$pub_cache"/hosted/*/"$RUNTIME_PACKAGE"-"$MEDIA_KIT_RUNTIME_VERSION")
[[ ${#runtime_candidates[@]} -eq 1 ]] || \
  fail "expected one resolved $RUNTIME_PACKAGE $MEDIA_KIT_RUNTIME_VERSION package, found ${#runtime_candidates[@]}"
runtime_platform_dir="${runtime_candidates[0]}/$PLATFORM"
marker="$runtime_platform_dir/.animewitcher-mpv-runtime.json"
[[ -f "$marker" ]] || fail "runtime overlay marker is missing: $marker"

python3 - "$marker" "$MPV_VERSION" "$MPV_OVERLAY_VERSION" "$MPV_RUNTIME_SHA256" "$MPV_RUNTIME_URL" "$PLATFORM" "$RUNTIME_PACKAGE" "$MEDIA_KIT_RUNTIME_VERSION" <<'PY'
import json
import sys

marker_path, tag, overlay, digest, url, platform, package, package_version = sys.argv[1:]
try:
    marker = json.load(open(marker_path, encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"runtime marker is invalid: {exc}")
expected = {
    "platform": platform,
    "package": package,
    "package_version": package_version,
    "mpv_tag": tag,
    "overlay_version": overlay,
    "sha256": digest,
    "source_url": url,
}
if any(marker.get(key) != value for key, value in expected.items()):
    raise SystemExit(f"runtime marker does not match pinned mpv {tag}")
PY

source_dir="$repo_root/third_party/mpv/$MPV_VERSION"
headers_dir="$package_dir/$PLATFORM/Headers/mpv"
makefile="$package_dir/common/darwin/Makefile"
[[ -d "$source_dir" ]] || fail "vendored mpv headers not found at $source_dir"
[[ -f "$makefile" ]] || fail "media_kit_video Darwin Makefile not found"

# First activation must happen from the exact upstream media_kit 2.0.1 layout.
# Subsequent invocations are idempotent and recognize our fail-closed stub.
if ! grep -Fq "AnimeWitcher: already pinned local headers" "$makefile"; then
  grep -Fq "MPV_HEADERS_VERSION=v0.36.0" "$makefile" || \
    fail "media_kit_video Darwin header layout changed unexpectedly"
  grep -Fq "MPV_HEADERS_SHA256SUM=29abc44f8ebee013bb2f9fe14d80b30db19b534c679056e4851ceadf5a5e8bf6" "$makefile" || \
    fail "media_kit_video Darwin header checksum changed unexpectedly"
fi

mkdir -p "$headers_dir"
for entry in "${contract[@]:1:4}"; do
  filename="${entry%% *}"
  expected_blob="${entry#* }"
  source_file="$source_dir/$filename"
  [[ -f "$source_file" ]] || fail "missing vendored header: $filename"
  actual_blob="$(git hash-object -- "$source_file")"
  [[ "$actual_blob" == "$expected_blob" ]] || \
    fail "$filename does not match the pinned mpv $MPV_VERSION source"
  cp -f "$source_file" "$headers_dir/$filename"
done

# CocoaPods evaluates the package podspec, which invokes this Makefile. The
# upstream target downloads v0.36 headers at pod-install time. Once the runtime
# marker proves the matching pinned v0.41 runtime is prepared, keep that hook
# but make it validate the already pinned local headers instead.
cat > "$makefile" <<'MAKEFILE'
# AnimeWitcher: already pinned local headers after verified runtime alignment.
all:
	@test -f "$(HEADERS_DESTDIR)/mpv/client.h"
	@test -f "$(HEADERS_DESTDIR)/mpv/render.h"
	@test -f "$(HEADERS_DESTDIR)/mpv/render_gl.h"
	@test -f "$(HEADERS_DESTDIR)/mpv/stream_cb.h"
MAKEFILE

make -C "$package_dir/common/darwin" HEADERS_DESTDIR="$package_dir/$PLATFORM/Headers"
echo "Prepared media_kit_video $MEDIA_KIT_VIDEO_VERSION $PLATFORM headers for verified mpv $MPV_VERSION runtime."
