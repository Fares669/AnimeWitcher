#!/usr/bin/env bash
set -euo pipefail

readonly MEDIA_KIT_VIDEO_VERSION="2.0.1"
readonly MPV_VERSION="v0.36.0"
readonly MPV_ARCHIVE_SHA256="29abc44f8ebee013bb2f9fe14d80b30db19b534c679056e4851ceadf5a5e8bf6"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pub_cache="${PUB_CACHE:-$HOME/.pub-cache}"
shopt -s nullglob
package_candidates=("$pub_cache"/hosted/*/media_kit_video-"$MEDIA_KIT_VIDEO_VERSION")
[[ ${#package_candidates[@]} -eq 1 ]] || {
  echo "media_kit iOS header preparation failed: expected one resolved media_kit_video $MEDIA_KIT_VIDEO_VERSION package, found ${#package_candidates[@]}" >&2
  exit 1
}
package_dir="${package_candidates[0]}"
source_dir="$repo_root/third_party/mpv/$MPV_VERSION"
headers_dir="$package_dir/ios/Headers/mpv"
makefile="$package_dir/common/darwin/Makefile"

fail() {
  echo "media_kit iOS header preparation failed: $*" >&2
  exit 1
}

[[ -d "$package_dir" ]] || fail "resolved package not found at $package_dir"
[[ -d "$source_dir" ]] || fail "vendored mpv headers not found at $source_dir"
[[ -f "$makefile" ]] || fail "media_kit_video Darwin Makefile not found"
grep -Fq "MPV_HEADERS_VERSION=$MPV_VERSION" "$makefile" || \
  fail "media_kit_video now targets a different mpv version"
grep -Fq "MPV_HEADERS_SHA256SUM=$MPV_ARCHIVE_SHA256" "$makefile" || \
  fail "media_kit_video mpv archive checksum changed unexpectedly"

mkdir -p "$headers_dir"
while read -r filename expected_blob; do
  [[ -n "$filename" ]] || continue
  source_file="$source_dir/$filename"
  [[ -f "$source_file" ]] || fail "missing vendored header: $filename"
  actual_blob="$(git hash-object -- "$source_file")"
  [[ "$actual_blob" == "$expected_blob" ]] || \
    fail "$filename does not match the pinned mpv $MPV_VERSION source"
  cp -f "$source_file" "$headers_dir/$filename"
done <<'HEADERS'
client.h b9697eb7416ba3f85f4efcde0f540f4ddd171def
render.h 29f9b91e9625ad27733fee68002a8018673df0e1
render_gl.h a2c31f0c725adb87dda538edbfc6247b175df19c
stream_cb.h 9d1c2cc8d307c62d1f394e8b1479eb86468c67af
HEADERS

# CocoaPods evaluates the package podspec, which invokes this Makefile. The
# upstream target downloads an archive from GitHub at pod-install time. Keep
# that hook, but make it validate the already pinned local headers instead.
cat > "$makefile" <<'MAKEFILE'
all:
	@test -f "$(HEADERS_DESTDIR)/mpv/client.h"
	@test -f "$(HEADERS_DESTDIR)/mpv/render.h"
	@test -f "$(HEADERS_DESTDIR)/mpv/render_gl.h"
	@test -f "$(HEADERS_DESTDIR)/mpv/stream_cb.h"
MAKEFILE

make -C "$package_dir/common/darwin" HEADERS_DESTDIR="$package_dir/ios/Headers"
echo "Prepared media_kit_video $MEDIA_KIT_VIDEO_VERSION with pinned mpv $MPV_VERSION headers."
