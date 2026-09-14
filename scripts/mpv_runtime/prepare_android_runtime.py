#!/usr/bin/env python3
"""Prepare and verify pinned AnimeWitcher mpv Android JAR overlays in media_kit."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import tempfile
import urllib.request
from pathlib import Path

PACKAGE = "media_kit_libs_android_video"
PACKAGE_VERSION = "1.3.8"
ABIS = ("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MD5_RE = re.compile(r"^[0-9a-f]{32}$")
BASELINE = {
    "arm64-v8a": {
        "url": "https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-arm64-v8a.jar",
        "md5": "83df25b61193af8fa815e373143ac9af",
    },
    "armeabi-v7a": {
        "url": "https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-armeabi-v7a.jar",
        "md5": "22e21526fefc0a2b8f17adbec9f57590",
    },
    "x86": {
        "url": "https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-x86.jar",
        "md5": "0d742b756dc9d1fcd84ea271d8b68f32",
    },
    "x86_64": {
        "url": "https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-x86_64.jar",
        "md5": "6fa26bf0459b11f1c0b0dbc29e5b940d",
    },
}


def _digest(path: Path, algorithm: str) -> str:
    value = hashlib.new(algorithm)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def _load_lock(repo_root: Path) -> dict:
    path = repo_root / "third_party/mpv/android-runtime.lock.json"
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"unable to read Android runtime lock: {exc}") from exc
    if not isinstance(obj, dict):
        raise RuntimeError("Android runtime lock must contain a JSON object")
    return obj


def _target_tag(lock: dict) -> str:
    try:
        tag = lock["target"]["mpv_tag"]
    except (KeyError, TypeError) as exc:
        raise RuntimeError(f"Android runtime lock is missing target.mpv_tag: {exc}") from exc
    if not isinstance(tag, str) or not tag.startswith("v"):
        raise RuntimeError("Android runtime lock has invalid target.mpv_tag")
    return tag


def _artifact_contract(lock: dict) -> dict[str, dict[str, str]]:
    artifacts = lock.get("artifacts")
    if not isinstance(artifacts, dict):
        raise RuntimeError("Android runtime lock is missing pinned artifacts")
    if set(artifacts) != set(ABIS):
        raise RuntimeError(
            "Android runtime lock must pin exactly: " + ", ".join(ABIS)
        )
    result: dict[str, dict[str, str]] = {}
    for abi in ABIS:
        entry = artifacts.get(abi)
        if not isinstance(entry, dict):
            raise RuntimeError(f"Android pinned artifact for {abi} must be an object")
        url = entry.get("url")
        sha256 = entry.get("sha256")
        if not isinstance(url, str) or not url:
            raise RuntimeError(f"Android pinned artifact for {abi} has invalid url")
        if not isinstance(sha256, str) or not SHA256_RE.fullmatch(sha256):
            raise RuntimeError(f"Android pinned artifact for {abi} has invalid sha256")
        result[abi] = {"url": url, "sha256": sha256}
    return result


def _find_package(pub_cache: Path) -> Path:
    expected = f"{PACKAGE}-{PACKAGE_VERSION}"
    candidates = sorted(pub_cache.glob(f"hosted/*/{expected}"))
    if len(candidates) != 1:
        raise RuntimeError(f"expected exactly one {expected} in pub cache, found {len(candidates)}")
    android_dir = candidates[0] / "android"
    if not android_dir.is_dir():
        raise RuntimeError(f"media_kit Android package directory is missing: {android_dir}")
    return android_dir


def _marker_path(android_dir: Path) -> Path:
    return android_dir / ".animewitcher-mpv-runtime.json"


def _download_and_verify(artifacts: dict[str, dict[str, str]], temp_dir: Path) -> dict[str, dict[str, str]]:
    verified: dict[str, dict[str, str]] = {}
    for abi in ABIS:
        entry = artifacts[abi]
        destination = temp_dir / f"default-{abi}.jar"
        try:
            with urllib.request.urlopen(entry["url"], timeout=120) as response, destination.open("wb") as output:
                shutil.copyfileobj(response, output)
        except (OSError, ValueError) as exc:
            raise RuntimeError(f"unable to download Android runtime for {abi}: {exc}") from exc
        actual_sha256 = _digest(destination, "sha256")
        if actual_sha256 != entry["sha256"]:
            raise RuntimeError(
                f"Android runtime SHA-256 mismatch for {abi}: expected {entry['sha256']}, got {actual_sha256}"
            )
        verified[abi] = {
            "url": entry["url"],
            "sha256": actual_sha256,
            "md5": _digest(destination, "md5"),
        }
    return verified


def _validate_baseline_gradle(text: str) -> None:
    for abi in ABIS:
        baseline = BASELINE[abi]
        if text.count(baseline["url"]) != 1 or text.count(baseline["md5"]) != 1:
            raise RuntimeError(
                f"media_kit Android Gradle drift detected for {abi}; refusing to patch unknown layout"
            )


def _matches_pinned_gradle(text: str, marker: dict) -> bool:
    entries = marker.get("artifacts")
    if not isinstance(entries, dict) or set(entries) != set(ABIS):
        return False
    for abi in ABIS:
        entry = entries.get(abi)
        if not isinstance(entry, dict):
            return False
        url = entry.get("url")
        md5 = entry.get("md5")
        if not isinstance(url, str) or not isinstance(md5, str):
            return False
        if text.count(url) != 1 or text.count(md5) != 1:
            return False
    return True


def prepare_runtime(*, repo_root: Path, pub_cache: Path) -> dict:
    lock = _load_lock(repo_root)
    target_tag = _target_tag(lock)
    artifacts = _artifact_contract(lock)
    android_dir = _find_package(pub_cache)
    gradle = android_dir / "build.gradle"
    try:
        original = gradle.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to read media_kit Android Gradle file: {exc}") from exc

    marker_path = _marker_path(android_dir)
    if marker_path.is_file():
        try:
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"invalid existing Android runtime overlay marker: {exc}") from exc
        if (
            marker.get("package") == PACKAGE
            and marker.get("package_version") == PACKAGE_VERSION
            and marker.get("mpv_tag") == target_tag
            and _matches_pinned_gradle(original, marker)
            and not verify_runtime(repo_root=repo_root, pub_cache=pub_cache)
        ):
            return marker
        raise RuntimeError("existing Android runtime overlay does not match requested runtime")

    # Never partially mutate Gradle. Validate both the original layout and every
    # candidate artifact first, then replace all four ABI entries atomically.
    _validate_baseline_gradle(original)
    with tempfile.TemporaryDirectory(prefix="animewitcher-mpv-android-") as temp:
        verified = _download_and_verify(artifacts, Path(temp))

    updated = original
    for abi in ABIS:
        baseline = BASELINE[abi]
        entry = verified[abi]
        updated = updated.replace(baseline["url"], entry["url"], 1)
        updated = updated.replace(baseline["md5"], entry["md5"], 1)

    marker = {
        "schema_version": 1,
        "package": PACKAGE,
        "package_version": PACKAGE_VERSION,
        "mpv_tag": target_tag,
        "artifacts": verified,
    }
    gradle.write_text(updated, encoding="utf-8")
    marker_path.write_text(json.dumps(marker, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return marker


def verify_runtime(*, repo_root: Path, pub_cache: Path) -> list[str]:
    errors: list[str] = []
    try:
        lock = _load_lock(repo_root)
        target_tag = _target_tag(lock)
        artifacts = _artifact_contract(lock)
        android_dir = _find_package(pub_cache)
    except RuntimeError as exc:
        return [str(exc)]

    marker_path = _marker_path(android_dir)
    if not marker_path.is_file():
        return [f"Android runtime overlay marker is missing: {marker_path}"]
    try:
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"invalid Android runtime overlay marker: {exc}"]

    if marker.get("package") != PACKAGE or marker.get("package_version") != PACKAGE_VERSION:
        errors.append("Android runtime overlay marker package mismatch")
    if marker.get("mpv_tag") != target_tag:
        errors.append(f"Android runtime overlay marker does not target {target_tag}")

    marker_artifacts = marker.get("artifacts")
    if not isinstance(marker_artifacts, dict) or set(marker_artifacts) != set(ABIS):
        errors.append("Android runtime overlay marker does not contain all four ABIs")
        marker_artifacts = {}

    for abi in ABIS:
        pinned = artifacts[abi]
        entry = marker_artifacts.get(abi)
        if not isinstance(entry, dict):
            continue
        if entry.get("url") != pinned["url"]:
            errors.append(f"Android runtime source URL mismatch for {abi}")
        if entry.get("sha256") != pinned["sha256"]:
            errors.append(f"Android runtime SHA-256 mismatch for {abi}")
        md5 = entry.get("md5")
        if not isinstance(md5, str) or not MD5_RE.fullmatch(md5):
            errors.append(f"Android runtime MD5 is invalid for {abi}")

    gradle = android_dir / "build.gradle"
    try:
        text = gradle.read_text(encoding="utf-8")
    except OSError as exc:
        errors.append(f"unable to read media_kit Android Gradle file: {exc}")
        return errors
    for abi in ABIS:
        entry = marker_artifacts.get(abi)
        if not isinstance(entry, dict):
            continue
        url = entry.get("url")
        md5 = entry.get("md5")
        if isinstance(url, str) and text.count(url) != 1:
            errors.append(f"media_kit Android Gradle URL is not pinned for {abi}")
        if isinstance(md5, str) and text.count(md5) != 1:
            errors.append(f"media_kit Android Gradle MD5 is not pinned for {abi}")
    return errors


def _default_repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _default_pub_cache() -> Path:
    import os

    return Path(os.environ.get("PUB_CACHE", Path.home() / ".pub-cache"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "verify"):
        command = sub.add_parser(name)
        command.add_argument("--repo-root", type=Path, default=_default_repo_root())
        command.add_argument("--pub-cache", type=Path, default=_default_pub_cache())
    args = parser.parse_args(argv)

    if args.command == "prepare":
        marker = prepare_runtime(repo_root=args.repo_root, pub_cache=args.pub_cache)
        print(json.dumps(marker, sort_keys=True))
        return 0

    errors = verify_runtime(repo_root=args.repo_root, pub_cache=args.pub_cache)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print("verified Android mpv runtime overlay")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
