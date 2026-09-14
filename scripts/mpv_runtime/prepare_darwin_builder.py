#!/usr/bin/env python3
"""Prepare media-kit's Darwin builder for AnimeWitcher's pinned mpv runtime."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path


def replace_package_block(text: str, name: str, *, version: str, url: str, sha256: str) -> str:
    pattern = re.compile(rf"(?ms)^  {re.escape(name)} = \{{.*?^  \}};")
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise RuntimeError(f"expected exactly one {name} block in packages.lock.nix; found {len(matches)}")
    replacement = (
        f'  {name} = {{\n'
        f'    version = "{version}";\n'
        f'    url = "{url}";\n'
        f'    sha256 = "{sha256}";\n'
        f'  }};'
    )
    return pattern.sub(replacement, text, count=1)


def git_head(directory: Path) -> str:
    return subprocess.check_output(
        ["git", "-C", str(directory), "rev-parse", "HEAD"], text=True
    ).strip()


OBSOLETE_FFMPEG_DASH_PATCH = "    patch -p1 <${../../../patches/ffmpeg-fix-dash-base-url-escape.patch}\n"
OBSOLETE_MPV_OBJC_PATCH = "    patch -p1 <${../../../patches/mpv-fix-missing-objc.patch}\n"
OLD_AUDIOUNIT_PATCH_MARKER = "-    [instance setCategory:AVAudioSessionCategoryPlayback error:nil];"


def prepare_patch_compatibility(builder: Path, repo_root: Path) -> None:
    ffmpeg_recipe = builder / "nix/packages/mk-pkg-ffmpeg/default.nix"
    text = ffmpeg_recipe.read_text(encoding="utf-8")
    count = text.count(OBSOLETE_FFMPEG_DASH_PATCH)
    if count != 1:
        raise RuntimeError(
            "expected exactly one obsolete FFmpeg DASH patch application; "
            f"found {count}"
        )
    ffmpeg_recipe.write_text(
        text.replace(OBSOLETE_FFMPEG_DASH_PATCH, "", 1), encoding="utf-8"
    )

    mpv_recipe = builder / "nix/packages/mk-pkg-mpv/default.nix"
    text = mpv_recipe.read_text(encoding="utf-8")
    count = text.count(OBSOLETE_MPV_OBJC_PATCH)
    if count != 1:
        raise RuntimeError(
            "expected exactly one obsolete mpv Objective-C patch application; "
            f"found {count}"
        )
    mpv_recipe.write_text(
        text.replace(OBSOLETE_MPV_OBJC_PATCH, "", 1), encoding="utf-8"
    )

    audio_patch = builder / "patches/mpv-audiounit-shared-session.patch"
    old_patch = audio_patch.read_text(encoding="utf-8")
    if OLD_AUDIOUNIT_PATCH_MARKER not in old_patch:
        raise RuntimeError("Darwin AudioUnit patch drifted before v0.41 rebase")

    rebased_patch = (
        repo_root
        / "third_party/mpv/patches/darwin-audiounit-shared-session-v0.41.patch"
    )
    audio_patch.write_text(rebased_patch.read_text(encoding="utf-8"), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--builder", type=Path, required=True)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--mpv-sha256", required=True)
    parser.add_argument("--ffmpeg-sha256", required=True)
    args = parser.parse_args()

    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    expected_builder = lock["builder"]["commit"]
    actual_builder = git_head(args.builder)
    if actual_builder != expected_builder:
        raise SystemExit(
            f"Darwin builder commit mismatch: expected {expected_builder}, got {actual_builder}"
        )

    mpv_commit = lock["target"]["mpv_commit"]
    mpv_tag = lock["target"]["mpv_tag"]
    ffmpeg_commit = lock["source_pins"]["ffmpeg"]
    ffmpeg_version = lock["source_pins"]["ffmpeg_release_marker"]

    package_lock = args.builder / "packages.lock.nix"
    text = package_lock.read_text(encoding="utf-8")
    text = replace_package_block(
        text,
        "ffmpeg",
        version=ffmpeg_version,
        url=f"https://github.com/FFmpeg/FFmpeg/archive/{ffmpeg_commit}.tar.gz",
        sha256=args.ffmpeg_sha256,
    )
    text = replace_package_block(
        text,
        "mpv",
        version=mpv_tag.removeprefix("v"),
        url=f"https://github.com/mpv-player/mpv/archive/{mpv_commit}.tar.gz",
        sha256=args.mpv_sha256,
    )
    package_lock.write_text(text, encoding="utf-8")

    repo_root = Path(__file__).resolve().parents[2]
    prepare_patch_compatibility(args.builder, repo_root)

    mpv_recipe = (args.builder / "nix/packages/mk-pkg-mpv/default.nix").read_text(
        encoding="utf-8"
    )
    required = [
        "-Dgpl=false",
        "-Dlibmpv=true",
    ]
    missing = [token for token in required if token not in mpv_recipe]
    if missing:
        raise SystemExit(f"Darwin builder policy drift; missing: {', '.join(missing)}")

    # Task 4 deliberately preserves the existing libmpv Render API first.
    # libplacebo/gpu-next is a separate Task 7 migration because mpv 0.41's
    # libmpv render API is not equivalent to standalone vo=gpu-next.
    if "-Dlibplacebo=disabled" not in mpv_recipe:
        raise SystemExit("Darwin core runtime unexpectedly enables libplacebo; revisit Task 7 boundary")

    print(f"prepared Darwin builder {actual_builder}")
    print(f"mpv={mpv_tag} ({mpv_commit})")
    print(f"ffmpeg={ffmpeg_version} ({ffmpeg_commit})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
