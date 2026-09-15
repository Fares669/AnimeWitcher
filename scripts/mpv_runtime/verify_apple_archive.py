#!/usr/bin/env python3
"""Verify an Apple mpv XCFramework archive before it is promoted or installed."""

from __future__ import annotations

import argparse
import hashlib
import json
import tarfile
from pathlib import Path, PurePosixPath

REQUIRED_SLICES = {
    "ios": {"ios-arm64", "ios-arm64_x86_64-simulator"},
    "macos": {"macos-arm64_x86_64"},
}


def _git_blob_sha(data: bytes) -> str:
    prefix = b"blob " + str(len(data)).encode("ascii") + b"\0"
    return hashlib.sha1(prefix + data).hexdigest()


def _slice_name(path: PurePosixPath) -> str | None:
    parts = path.parts
    try:
        index = parts.index("Mpv.xcframework")
    except ValueError:
        return None
    if index + 2 >= len(parts) or parts[index + 2] != "Mpv.framework":
        return None
    return parts[index + 1]


def verify_archive(
    archive: Path,
    platform: str,
    target_tag: str,
    expected_headers: dict[str, str],
) -> list[str]:
    errors: list[str] = []
    required_slices = REQUIRED_SLICES.get(platform)
    if required_slices is None:
        return [f"unsupported Apple platform: {platform}"]
    if not archive.is_file():
        return [f"runtime archive does not exist: {archive}"]

    version_marker = f"mpv {target_tag}".encode("ascii")
    binaries: dict[str, bytes] = {}
    headers: dict[str, dict[str, bytes]] = {}
    try:
        with tarfile.open(archive, "r:*") as bundle:
            for member in bundle.getmembers():
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts:
                    errors.append(f"unsafe path in runtime archive: {member.name}")
                    continue
                if not member.isfile():
                    continue
                slice_name = _slice_name(path)
                if slice_name is None:
                    continue
                handle = bundle.extractfile(member)
                if handle is None:
                    errors.append(f"unable to read runtime archive member: {member.name}")
                    continue
                data = handle.read()
                if path.name == "Mpv":
                    if slice_name in binaries:
                        errors.append(f"duplicate Mpv binary for slice: {slice_name}")
                    else:
                        binaries[slice_name] = data
                elif path.name in expected_headers and "Headers" in path.parts:
                    headers.setdefault(slice_name, {})[path.name] = data
    except (tarfile.TarError, OSError) as exc:
        return [f"unable to inspect runtime archive: {exc}"]

    for slice_name in sorted(required_slices):
        binary = binaries.get(slice_name)
        if binary is None:
            errors.append(f"missing required Mpv slice: {slice_name}")
        elif version_marker not in binary:
            errors.append(f"Mpv binary for {slice_name} does not identify as mpv {target_tag}")

        slice_headers = headers.get(slice_name, {})
        for filename, expected_blob in sorted(expected_headers.items()):
            data = slice_headers.get(filename)
            if data is None:
                errors.append(f"missing {filename} in Mpv slice: {slice_name}")
                continue
            actual_blob = _git_blob_sha(data)
            if actual_blob != expected_blob:
                errors.append(
                    f"{filename} blob mismatch in {slice_name}: "
                    f"expected {expected_blob}, got {actual_blob}"
                )

    unexpected_slices = sorted(set(binaries) - required_slices)
    for slice_name in unexpected_slices:
        errors.append(f"unexpected Mpv slice for {platform}: {slice_name}")
    return errors


def _load_contract(repo_root: Path) -> tuple[str, dict[str, str]]:
    lock_path = repo_root / "third_party/mpv/darwin-runtime.lock.json"
    manifest_path = repo_root / "third_party/mpv/integration.json"
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        target_tag = lock["target"]["mpv_tag"]
        headers = manifest["target"]["headers"]
    except (OSError, KeyError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"unable to read Apple runtime verification contract: {exc}") from exc
    if target_tag != manifest.get("target", {}).get("tag"):
        raise RuntimeError("Darwin runtime lock target does not match integration target")
    if not isinstance(headers, dict) or not headers:
        raise RuntimeError("integration target header contract is missing")
    return target_tag, headers


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=sorted(REQUIRED_SLICES), required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    args = parser.parse_args(argv)
    try:
        target_tag, headers = _load_contract(args.repo_root)
    except RuntimeError as exc:
        print(f"ERROR: {exc}")
        return 1
    errors = verify_archive(args.archive, args.platform, target_tag, headers)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(f"verified Apple {args.platform} archive: mpv {target_tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
