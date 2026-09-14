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
OLD_FFMPEG_VP9_PROGRESS_BLOCK = (
    "+    .caps_internal         = FF_CODEC_CAP_INIT_CLEANUP |\n"
    "+                                FF_CODEC_CAP_SLICE_THREAD_HAS_MF |\n"
    "+                                FF_CODEC_CAP_ALLOCATE_PROGRESS,\n"
)
NEW_FFMPEG_VP9_PROGRESS_BLOCK = (
    "+    .caps_internal         = FF_CODEC_CAP_INIT_CLEANUP |\n"
    "+                                FF_CODEC_CAP_SLICE_THREAD_HAS_MF |\n"
    "+                                FF_CODEC_CAP_USES_PROGRESSFRAMES,\n"
)
OBSOLETE_MPV_OPTION_TOKENS = (
    "-Dlibplacebo=disabled",
    "-Dmacos-10-11-features=disabled",
    "-Dmacos-10-12-2-features=disabled",
    "-Dmacos-10-14-features=disabled",
    "-Drpi=disabled",
    "-Drpi-mmal=disabled",
    "-Dsdl2=disabled",
    "-Dstdatomic=disabled",
    "-Dta-leak-report=false",
    "-Dvaapi-x-egl=disabled",
    "-Dwin32-internal-pthreads=disabled",
)
OLD_AUDIOUNIT_PATCH_MARKER = "-    [instance setCategory:AVAudioSessionCategoryPlayback error:nil];"


def remove_obsolete_mpv_options(text: str) -> str:
    for token in OBSOLETE_MPV_OPTION_TOKENS:
        pattern = re.compile(rf"(?m)^.*{re.escape(token)}.*\n")
        matches = list(pattern.finditer(text))
        if len(matches) != 1:
            raise RuntimeError(
                f"expected exactly one obsolete mpv option {token}; found {len(matches)}"
            )
        text = pattern.sub("", text, count=1)
    return text


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

    vp9_patch = builder / "patches/ffmpeg-fix-vp9-hwaccel.patch"
    text = vp9_patch.read_text(encoding="utf-8")
    progress_count = text.count(OLD_FFMPEG_VP9_PROGRESS_BLOCK)
    if progress_count != 1:
        raise RuntimeError(
            "FFmpeg VP9 VideoToolbox patch drifted before FFmpeg 8 rebase: "
            f"progress={progress_count}"
        )
    vp9_patch.write_text(
        text.replace(
            OLD_FFMPEG_VP9_PROGRESS_BLOCK,
            NEW_FFMPEG_VP9_PROGRESS_BLOCK,
            1,
        ),
        encoding="utf-8",
    )

    mpv_recipe = builder / "nix/packages/mk-pkg-mpv/default.nix"
    text = mpv_recipe.read_text(encoding="utf-8")
    count = text.count(OBSOLETE_MPV_OBJC_PATCH)
    if count != 1:
        raise RuntimeError(
            "expected exactly one obsolete mpv Objective-C patch application; "
            f"found {count}"
        )
    text = text.replace(OBSOLETE_MPV_OBJC_PATCH, "", 1)
    text = remove_obsolete_mpv_options(text)
    mpv_recipe.write_text(text, encoding="utf-8")

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

    remaining_obsolete = [token for token in OBSOLETE_MPV_OPTION_TOKENS if token in mpv_recipe]
    if remaining_obsolete:
        raise SystemExit(
            "Darwin builder still passes removed mpv 0.41 options: "
            + ", ".join(remaining_obsolete)
        )

    # mpv 0.41 requires libplacebo as a build dependency; it is no longer a
    # feature option. Task 4 still preserves the existing libmpv Render API.
    # Explicit gpu-next selection remains a separate Task 7 application policy.
    if "-Dgl=enabled" not in mpv_recipe or "-Dplain-gl=enabled" not in mpv_recipe:
        raise SystemExit("Darwin Render API policy drift; expected GL/plain-gl support")

    print(f"prepared Darwin builder {actual_builder}")
    print(f"mpv={mpv_tag} ({mpv_commit})")
    print(f"ffmpeg={ffmpeg_version} ({ffmpeg_commit})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
