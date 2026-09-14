#!/usr/bin/env python3
"""Prepare and verify a pinned AnimeWitcher mpv XCFramework overlay in media_kit's pub cache."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path, PurePosixPath

PLATFORM_SPECS = {
    "ios": {
        "package": "media_kit_libs_ios_video",
        "package_version": "1.1.4",
        "upstream_runtime": "v0.7.2",
        "upstream_sha256": "a0dbcddc0eaefa5534eb2bdc797e5386b1e0cd4057ed8f73aa2dd6105503dffb",
    },
    "macos": {
        "package": "media_kit_libs_macos_video",
        "package_version": "1.1.4",
        "upstream_runtime": "v0.7.2",
        "upstream_sha256": "dd9928fff9c97329e17f69fe8ef0d621cf458f9f70847955f84b4eb1e9047b09",
    },
}
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_lock(repo_root: Path) -> dict:
    lock = repo_root / "third_party/mpv/darwin-runtime.lock.json"
    try:
        obj = json.loads(lock.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"unable to read Darwin runtime lock: {exc}") from exc
    if not isinstance(obj, dict):
        raise RuntimeError("Darwin runtime lock must contain a JSON object")
    return obj


def _load_target_tag(repo_root: Path) -> str:
    obj = _load_lock(repo_root)
    try:
        tag = obj["target"]["mpv_tag"]
    except (KeyError, TypeError) as exc:
        raise RuntimeError(f"unable to read Darwin runtime lock: {exc}") from exc
    if not isinstance(tag, str) or not tag.startswith("v"):
        raise RuntimeError("Darwin runtime lock has an invalid target.mpv_tag")
    return tag


def _spec(platform: str) -> dict[str, str]:
    try:
        return PLATFORM_SPECS[platform]
    except KeyError as exc:
        raise RuntimeError(f"unsupported Apple platform: {platform}") from exc


def _find_package(pub_cache: Path, platform: str) -> Path:
    spec = _spec(platform)
    expected = f"{spec['package']}-{spec['package_version']}"
    candidates = sorted(pub_cache.glob(f"hosted/*/{expected}"))
    if len(candidates) != 1:
        raise RuntimeError(
            f"expected exactly one {expected} in pub cache, found {len(candidates)}"
        )
    platform_dir = candidates[0] / platform
    if not platform_dir.is_dir():
        raise RuntimeError(f"media_kit package is missing {platform}/ directory: {platform_dir}")
    return platform_dir


def _validate_archive(archive: Path) -> None:
    if not archive.is_file():
        raise RuntimeError(f"runtime archive does not exist: {archive}")
    try:
        with tarfile.open(archive, "r:*") as bundle:
            names = []
            for member in bundle.getmembers():
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts:
                    raise RuntimeError(f"unsafe path in runtime archive: {member.name}")
                names.append(member.name.lstrip("./"))
    except (tarfile.TarError, OSError) as exc:
        raise RuntimeError(f"unable to inspect runtime archive: {exc}") from exc
    if not any(
        name == "Mpv.xcframework" or name.startswith("Mpv.xcframework/")
        or "/Mpv.xcframework/" in f"/{name}"
        for name in names
    ):
        raise RuntimeError("runtime archive does not contain Mpv.xcframework")


def _marker_path(platform_dir: Path) -> Path:
    return platform_dir / ".animewitcher-mpv-runtime.json"


def _cache_path(platform_dir: Path, platform: str, overlay_version: str) -> Path:
    return (
        platform_dir
        / ".cache/xcframeworks"
        / f"libmpv-xcframeworks-{overlay_version}-{platform}-universal.tar.gz"
    )


def prepare_runtime(
    *,
    repo_root: Path,
    pub_cache: Path,
    platform: str,
    archive: Path,
    expected_sha256: str,
    overlay_version: str,
    source_url: str | None = None,
) -> dict[str, str]:
    spec = _spec(platform)
    target_tag = _load_target_tag(repo_root)
    if not overlay_version.startswith(f"{target_tag}-animewitcher."):
        raise RuntimeError(
            f"overlay version {overlay_version!r} is not tied to target {target_tag}"
        )
    if not SHA256_RE.fullmatch(expected_sha256):
        raise RuntimeError("expected SHA-256 must be 64 lowercase hexadecimal characters")

    archive = archive.resolve()
    actual_sha256 = _sha256(archive) if archive.is_file() else ""
    if actual_sha256 != expected_sha256:
        raise RuntimeError(
            f"runtime archive SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256 or 'missing'}"
        )
    _validate_archive(archive)

    platform_dir = _find_package(pub_cache, platform)
    makefile = platform_dir / "Makefile"
    try:
        text = makefile.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to read media_kit Makefile: {exc}") from exc

    marker_file = _marker_path(platform_dir)
    cache_file = _cache_path(platform_dir, platform, overlay_version)
    if marker_file.is_file():
        try:
            marker = json.loads(marker_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"invalid existing runtime overlay marker: {exc}") from exc
        source_matches = source_url is None or marker.get("source_url") == source_url
        if (
            marker.get("platform") == platform
            and marker.get("mpv_tag") == target_tag
            and marker.get("overlay_version") == overlay_version
            and marker.get("sha256") == expected_sha256
            and source_matches
            and f"MPV_XCFRAMEWORKS_VERSION={overlay_version}" in text
            and f"MPV_XCFRAMEWORKS_SHA256SUM={expected_sha256}" in text
            and cache_file.is_file()
            and _sha256(cache_file) == expected_sha256
        ):
            _validate_archive(cache_file)
            return marker
        raise RuntimeError("existing Apple runtime overlay does not match requested runtime")

    old_version = f"MPV_XCFRAMEWORKS_VERSION={spec['upstream_runtime']}"
    old_sha = f"MPV_XCFRAMEWORKS_SHA256SUM={spec['upstream_sha256']}"
    if text.count(old_version) != 1 or text.count(old_sha) != 1:
        raise RuntimeError(
            "media_kit Apple runtime Makefile drift detected; refusing to patch unknown layout"
        )

    updated = text.replace(old_version, f"MPV_XCFRAMEWORKS_VERSION={overlay_version}", 1)
    updated = updated.replace(old_sha, f"MPV_XCFRAMEWORKS_SHA256SUM={expected_sha256}", 1)

    cache_dir = platform_dir / ".cache/xcframeworks"
    if cache_dir.exists():
        shutil.rmtree(cache_dir)
    cache_dir.mkdir(parents=True)
    shutil.copy2(archive, cache_file)

    frameworks = platform_dir / "Frameworks"
    if frameworks.exists():
        for child in frameworks.iterdir():
            if child.name.endswith(".xcframework") or child.name == ".symlinks":
                if child.is_dir() and not child.is_symlink():
                    shutil.rmtree(child)
                else:
                    child.unlink()

    makefile.write_text(updated, encoding="utf-8")
    marker = {
        "schema_version": 1,
        "platform": platform,
        "package": spec["package"],
        "package_version": spec["package_version"],
        "mpv_tag": target_tag,
        "overlay_version": overlay_version,
        "sha256": expected_sha256,
        "cache_file": cache_file.name,
    }
    if source_url is not None:
        marker["source_url"] = source_url
    marker_file.write_text(json.dumps(marker, indent=2) + "\n", encoding="utf-8")
    return marker


def prepare_pinned_runtime(
    *,
    repo_root: Path,
    pub_cache: Path,
    platform: str,
) -> dict[str, str]:
    _spec(platform)
    lock = _load_lock(repo_root)
    artifacts = lock.get("artifacts")
    entry = artifacts.get(platform) if isinstance(artifacts, dict) else None
    if not isinstance(entry, dict):
        raise RuntimeError(f"Darwin runtime lock is missing pinned artifact for {platform}")

    url = entry.get("url")
    expected_sha256 = entry.get("sha256")
    overlay_version = entry.get("overlay_version")
    if not isinstance(url, str) or not url:
        raise RuntimeError(f"Darwin runtime lock pinned artifact for {platform} has invalid url")
    if not isinstance(expected_sha256, str) or not SHA256_RE.fullmatch(expected_sha256):
        raise RuntimeError(f"Darwin runtime lock pinned artifact for {platform} has invalid sha256")
    target_tag = _load_target_tag(repo_root)
    if not isinstance(overlay_version, str) or not overlay_version.startswith(
        f"{target_tag}-animewitcher."
    ):
        raise RuntimeError(
            f"Darwin runtime lock pinned artifact for {platform} has invalid overlay_version"
        )

    with tempfile.TemporaryDirectory(prefix=f"animewitcher-mpv-{platform}-") as temp_dir:
        archive = Path(temp_dir) / "runtime.tar.gz"
        try:
            with urllib.request.urlopen(url, timeout=120) as response, archive.open("wb") as output:
                shutil.copyfileobj(response, output)
        except (OSError, ValueError) as exc:
            raise RuntimeError(f"unable to download pinned Apple runtime for {platform}: {exc}") from exc
        return prepare_runtime(
            repo_root=repo_root,
            pub_cache=pub_cache,
            platform=platform,
            archive=archive,
            expected_sha256=expected_sha256,
            overlay_version=overlay_version,
            source_url=url,
        )


def verify_runtime(
    *,
    repo_root: Path,
    pub_cache: Path,
    platform: str,
    require_extracted: bool = False,
) -> list[str]:
    errors: list[str] = []
    try:
        spec = _spec(platform)
        target_tag = _load_target_tag(repo_root)
        platform_dir = _find_package(pub_cache, platform)
    except RuntimeError as exc:
        return [str(exc)]

    marker_file = _marker_path(platform_dir)
    if not marker_file.is_file():
        return [f"runtime overlay marker is missing: {marker_file}"]
    try:
        marker = json.loads(marker_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"invalid runtime overlay marker: {exc}"]

    if marker.get("platform") != platform:
        errors.append("runtime overlay marker platform mismatch")
    if marker.get("package") != spec["package"] or marker.get("package_version") != spec["package_version"]:
        errors.append("runtime overlay marker package mismatch")
    if marker.get("mpv_tag") != target_tag:
        errors.append(f"runtime overlay marker does not target {target_tag}")

    overlay_version = marker.get("overlay_version")
    expected_sha256 = marker.get("sha256")
    if not isinstance(overlay_version, str) or not overlay_version.startswith(f"{target_tag}-animewitcher."):
        errors.append("runtime overlay version is invalid")
    if not isinstance(expected_sha256, str) or not SHA256_RE.fullmatch(expected_sha256):
        errors.append("runtime overlay SHA-256 is invalid")

    lock = _load_lock(repo_root)
    artifacts = lock.get("artifacts")
    pinned = artifacts.get(platform) if isinstance(artifacts, dict) else None
    if isinstance(pinned, dict):
        if marker.get("overlay_version") != pinned.get("overlay_version"):
            errors.append("runtime overlay version does not match pinned artifact")
        if marker.get("sha256") != pinned.get("sha256"):
            errors.append("runtime overlay SHA-256 does not match pinned artifact")
        if marker.get("source_url") != pinned.get("url"):
            errors.append("runtime overlay source URL does not match pinned artifact")

    makefile = platform_dir / "Makefile"
    try:
        text = makefile.read_text(encoding="utf-8")
    except OSError as exc:
        errors.append(f"unable to read media_kit Makefile: {exc}")
        return errors
    if isinstance(overlay_version, str) and f"MPV_XCFRAMEWORKS_VERSION={overlay_version}" not in text:
        errors.append("media_kit Makefile runtime version is not the prepared overlay")
    if isinstance(expected_sha256, str) and f"MPV_XCFRAMEWORKS_SHA256SUM={expected_sha256}" not in text:
        errors.append("media_kit Makefile runtime SHA-256 is not the prepared overlay")

    if isinstance(overlay_version, str) and isinstance(expected_sha256, str):
        cache_file = _cache_path(platform_dir, platform, overlay_version)
        if not cache_file.is_file():
            errors.append(f"prepared runtime archive is missing: {cache_file}")
        else:
            actual = _sha256(cache_file)
            if actual != expected_sha256:
                errors.append(
                    f"prepared runtime archive SHA-256 mismatch: expected {expected_sha256}, got {actual}"
                )
            else:
                try:
                    _validate_archive(cache_file)
                except RuntimeError as exc:
                    errors.append(str(exc))

    if require_extracted and not (platform_dir / "Frameworks/Mpv.xcframework").is_dir():
        errors.append("Mpv.xcframework has not been extracted by media_kit")
    return errors


def _default_repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    prepare = sub.add_parser("prepare")
    prepare.add_argument("--platform", choices=sorted(PLATFORM_SPECS), required=True)
    prepare.add_argument("--archive", type=Path, required=True)
    prepare.add_argument("--sha256", required=True)
    prepare.add_argument("--overlay-version", required=True)
    prepare.add_argument("--pub-cache", type=Path, required=True)
    prepare.add_argument("--repo-root", type=Path, default=_default_repo_root())

    prepare_pinned = sub.add_parser("prepare-pinned")
    prepare_pinned.add_argument("--platform", choices=sorted(PLATFORM_SPECS), required=True)
    prepare_pinned.add_argument("--pub-cache", type=Path, required=True)
    prepare_pinned.add_argument("--repo-root", type=Path, default=_default_repo_root())

    verify = sub.add_parser("verify")
    verify.add_argument("--platform", choices=sorted(PLATFORM_SPECS), required=True)
    verify.add_argument("--pub-cache", type=Path, required=True)
    verify.add_argument("--repo-root", type=Path, default=_default_repo_root())
    verify.add_argument("--require-extracted", action="store_true")

    args = parser.parse_args(argv)
    if args.command == "prepare":
        marker = prepare_runtime(
            repo_root=args.repo_root,
            pub_cache=args.pub_cache,
            platform=args.platform,
            archive=args.archive,
            expected_sha256=args.sha256,
            overlay_version=args.overlay_version,
        )
        print(json.dumps(marker, sort_keys=True))
        return 0

    if args.command == "prepare-pinned":
        marker = prepare_pinned_runtime(
            repo_root=args.repo_root,
            pub_cache=args.pub_cache,
            platform=args.platform,
        )
        print(json.dumps(marker, sort_keys=True))
        return 0

    errors = verify_runtime(
        repo_root=args.repo_root,
        pub_cache=args.pub_cache,
        platform=args.platform,
        require_extracted=args.require_extracted,
    )
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(f"verified Apple runtime overlay for {args.platform}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
