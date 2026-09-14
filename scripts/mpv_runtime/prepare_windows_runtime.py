#!/usr/bin/env python3
"""Prepare and verify AnimeWitcher's pinned Windows libmpv runtime override."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
import urllib.request
from pathlib import Path

PACKAGE = "media_kit_libs_windows_video"
PACKAGE_VERSION = "1.0.11"
BASELINE_VERSION = "20241021"
BASELINE_URL = "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20241021/mpv-dev-x86_64-20241021-git-0f78584.7z"
BASELINE_MD5 = "d82e6f02f290d391e9aa30121ace8ec8"
TARGET_FILENAME = "libmpv-2.dll"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_lock(repo_root: Path) -> dict:
    path = repo_root / "third_party/mpv/windows-runtime.lock.json"
    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"unable to read Windows runtime lock: {exc}") from exc
    if not isinstance(obj, dict):
        raise RuntimeError("Windows runtime lock must contain a JSON object")
    return obj


def _contract(lock: dict) -> tuple[str, str, str, str]:
    try:
        tag = lock["target"]["mpv_tag"]
        artifact = lock["artifact"]
        url = artifact["url"]
        sha256 = artifact["sha256"]
        filename = artifact["filename"]
    except (KeyError, TypeError) as exc:
        raise RuntimeError(f"Windows runtime lock is missing pinned artifact data: {exc}") from exc
    if tag != "v0.41.0":
        raise RuntimeError(f"Windows runtime lock targets unexpected mpv version: {tag!r}")
    if not isinstance(url, str) or not url:
        raise RuntimeError("Windows pinned artifact URL is invalid")
    if not isinstance(sha256, str) or len(sha256) != 64 or any(c not in "0123456789abcdef" for c in sha256):
        raise RuntimeError("Windows pinned artifact SHA-256 is invalid")
    if filename != TARGET_FILENAME:
        raise RuntimeError(f"Windows pinned artifact filename must be {TARGET_FILENAME}")
    return tag, url, sha256, filename


def _find_package(pub_cache: Path) -> Path:
    expected = f"{PACKAGE}-{PACKAGE_VERSION}"
    candidates = sorted(pub_cache.glob(f"hosted/*/{expected}"))
    if len(candidates) != 1:
        raise RuntimeError(f"expected exactly one {expected} in pub cache, found {len(candidates)}")
    windows_dir = candidates[0] / "windows"
    if not windows_dir.is_dir():
        raise RuntimeError(f"media_kit Windows package directory is missing: {windows_dir}")
    return windows_dir


def _validate_media_kit_boundary(cmake: Path) -> None:
    try:
        text = cmake.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to read media_kit Windows CMake file: {exc}") from exc
    expected = (
        f'set(LIBMPV_VERSION "{BASELINE_VERSION}" CACHE STRING "libmpv version")',
        f'set(LIBMPV_URL "{BASELINE_URL}")',
        f'set(LIBMPV_MD5 "{BASELINE_MD5}")',
    )
    if any(text.count(item) != 1 for item in expected):
        raise RuntimeError(
            "media_kit Windows CMake drift detected; refusing to override an unknown runtime boundary"
        )


def _override_dir(repo_root: Path) -> Path:
    return repo_root / "third_party/mpv/shinchiro"


def _marker_path(repo_root: Path) -> Path:
    return _override_dir(repo_root) / ".animewitcher-mpv-runtime.json"


def _dll_path(repo_root: Path) -> Path:
    return _override_dir(repo_root) / TARGET_FILENAME


def prepare_runtime(*, repo_root: Path, pub_cache: Path) -> dict:
    lock = _load_lock(repo_root)
    tag, url, expected_sha256, filename = _contract(lock)
    package_dir = _find_package(pub_cache)
    _validate_media_kit_boundary(package_dir / "CMakeLists.txt")

    destination = _dll_path(repo_root)
    marker_path = _marker_path(repo_root)
    if destination.is_file() and marker_path.is_file():
        try:
            marker = json.loads(marker_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"invalid existing Windows runtime marker: {exc}") from exc
        if (
            marker.get("mpv_tag") == tag
            and marker.get("source_url") == url
            and marker.get("sha256") == expected_sha256
            and marker.get("filename") == filename
            and _sha256(destination) == expected_sha256
        ):
            return marker
        raise RuntimeError("existing Windows runtime override does not match pinned runtime")

    # Validate the whole candidate before touching the repository override path.
    with tempfile.TemporaryDirectory(prefix="animewitcher-mpv-windows-") as temp:
        candidate = Path(temp) / filename
        try:
            with urllib.request.urlopen(url, timeout=120) as response, candidate.open("wb") as output:
                shutil.copyfileobj(response, output)
        except (OSError, ValueError) as exc:
            raise RuntimeError(f"unable to download pinned Windows runtime: {exc}") from exc
        actual_sha256 = _sha256(candidate)
        if actual_sha256 != expected_sha256:
            raise RuntimeError(
                f"Windows runtime SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256}"
            )
        # A PE image starts with the DOS MZ signature. This catches accidental
        # HTML/error payloads even when a lock entry itself was authored badly.
        if candidate.read_bytes()[:2] != b"MZ":
            raise RuntimeError("Windows runtime candidate is not a PE DLL (missing MZ signature)")

        override_dir = _override_dir(repo_root)
        override_dir.mkdir(parents=True, exist_ok=True)
        staged = override_dir / f".{filename}.tmp"
        shutil.copy2(candidate, staged)
        staged.replace(destination)

    marker = {
        "schema_version": 1,
        "mpv_tag": tag,
        "package": PACKAGE,
        "package_version": PACKAGE_VERSION,
        "source_url": url,
        "sha256": expected_sha256,
        "filename": filename,
    }
    marker_path.write_text(json.dumps(marker, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return marker


def verify_runtime(*, repo_root: Path, pub_cache: Path) -> list[str]:
    errors: list[str] = []
    try:
        lock = _load_lock(repo_root)
        tag, url, expected_sha256, filename = _contract(lock)
        package_dir = _find_package(pub_cache)
        _validate_media_kit_boundary(package_dir / "CMakeLists.txt")
    except RuntimeError as exc:
        return [str(exc)]

    destination = _dll_path(repo_root)
    marker_path = _marker_path(repo_root)
    if not marker_path.is_file():
        return [f"Windows runtime override marker is missing: {marker_path}"]
    if not destination.is_file():
        return [f"Windows runtime override DLL is missing: {destination}"]
    try:
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"invalid Windows runtime override marker: {exc}"]

    expected_marker = {
        "mpv_tag": tag,
        "package": PACKAGE,
        "package_version": PACKAGE_VERSION,
        "source_url": url,
        "sha256": expected_sha256,
        "filename": filename,
    }
    for key, value in expected_marker.items():
        if marker.get(key) != value:
            errors.append(f"Windows runtime override marker {key} mismatch")
    actual_sha256 = _sha256(destination)
    if actual_sha256 != expected_sha256:
        errors.append(
            f"Windows runtime override SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256}"
        )
    try:
        if destination.read_bytes()[:2] != b"MZ":
            errors.append("Windows runtime override is not a PE DLL")
    except OSError as exc:
        errors.append(f"unable to inspect Windows runtime override: {exc}")
    return errors


def _default_repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _default_pub_cache() -> Path:
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
    print("verified Windows mpv runtime override")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
