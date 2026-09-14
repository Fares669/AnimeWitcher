#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

TARGET_TAG = "v0.41.0"
PRIMARY_RENDERER = "gpu-next"
FALLBACK_RENDERER = "gpu"
EXPECTED_MEDIA_KIT = {
    "media_kit": "1.2.6",
    "media_kit_video": "2.0.1",
    "media_kit_libs_video": "1.0.7",
}
EXPECTED_HEADERS = {
    "client.h": "85cff63bd5d20797ca622834fd904d506d0d4fd8",
    "render.h": "99aadeb5d837dd47a8a170ae55672cf46ec5f4c4",
    "render_gl.h": "aa2719d5c4ebfa1ecaee469b563d138e10b1df4e",
    "stream_cb.h": "9ae6f31a16847d9a695886a78bc1b7a2c9942a27",
}
EXPECTED_PLATFORMS = {"ios", "macos", "android", "windows"}
ALLOWED_PLATFORM_STATUS = {"pending", "upgraded", "blocked"}


def _dependency_constraint(pubspec_text: str, package: str):
    match = re.search(
        rf"^\s{{2}}{re.escape(package)}:\s*([^#\n]+)",
        pubspec_text,
        re.MULTILINE,
    )
    return match.group(1).strip().strip('"\'') if match else None


def _locked_version(lock_text: str, package: str):
    lines = lock_text.splitlines()
    start = None
    marker = f"  {package}:"
    for index, line in enumerate(lines):
        if line == marker:
            start = index + 1
            break
    if start is None:
        return None

    for line in lines[start:]:
        if line.startswith("  ") and not line.startswith("    "):
            break
        stripped = line.strip()
        if stripped.startswith("version:"):
            return stripped.split(":", 1)[1].strip().strip('"\'')
    return None


def _constraint_allows_version(constraint: str, expected: str) -> bool:
    if constraint is None:
        return False
    return constraint in {expected, f"^{expected}"}


def _git_blob_hash(data: bytes) -> str:
    prefix = f"blob {len(data)}\0".encode("ascii")
    return hashlib.sha1(prefix + data).hexdigest()


def validate_target_headers(manifest, repo_root: Path):
    errors = []
    target = manifest.get("target") if isinstance(manifest, dict) else None
    if not isinstance(target, dict):
        return ["target must be an object before target headers can be verified"]

    tag = target.get("tag")
    hashes = target.get("headers")
    if tag != TARGET_TAG or not isinstance(hashes, dict):
        return ["target tag/header manifest is invalid before target headers can be verified"]

    header_dir = Path(repo_root) / "third_party" / "mpv" / tag
    for name, expected_hash in EXPECTED_HEADERS.items():
        path = header_dir / name
        if not path.is_file():
            errors.append(f"target header {name} is missing at {path}")
            continue
        actual_hash = _git_blob_hash(path.read_bytes())
        manifest_hash = hashes.get(name)
        if manifest_hash != expected_hash:
            errors.append(
                f"target header manifest hash for {name} must be {expected_hash}; "
                f"found {manifest_hash or 'missing'}"
            )
        if actual_hash != expected_hash:
            errors.append(
                f"target header {name} blob hash must be {expected_hash}; "
                f"found {actual_hash}"
            )
    return errors


def validate_manifest(manifest, repo_root: Path):
    errors = []

    target = manifest.get("target")
    if not isinstance(target, dict):
        errors.append("target must be an object")
        target = {}
    if target.get("tag") != TARGET_TAG:
        errors.append(f"target.tag must be {TARGET_TAG}")

    headers = target.get("headers")
    if headers != EXPECTED_HEADERS:
        if not isinstance(headers, dict):
            errors.append("target.headers must contain the approved v0.41.0 hashes")
        else:
            for name, approved_hash in EXPECTED_HEADERS.items():
                if headers.get(name) != approved_hash:
                    errors.append(f"target.headers[{name}] must be {approved_hash}")
            for name in sorted(set(headers) - set(EXPECTED_HEADERS)):
                errors.append(f"target.headers contains unexpected file {name}")

    renderer = manifest.get("renderer")
    if not isinstance(renderer, dict):
        errors.append("renderer must be an object")
        renderer = {}
    if renderer.get("primary") != PRIMARY_RENDERER:
        errors.append(f"renderer.primary must be {PRIMARY_RENDERER}")
    if renderer.get("fallback") != FALLBACK_RENDERER:
        errors.append(f"renderer.fallback must be {FALLBACK_RENDERER}")

    media_kit = manifest.get("media_kit")
    if not isinstance(media_kit, dict):
        errors.append("media_kit must be an object")
        media_kit = {}
    for package, expected_version in EXPECTED_MEDIA_KIT.items():
        if media_kit.get(package) != expected_version:
            errors.append(f"media_kit.{package} must be {expected_version}")

    platforms = manifest.get("platforms")
    if not isinstance(platforms, dict):
        errors.append("platforms must be an object")
        platforms = {}
    missing_platforms = EXPECTED_PLATFORMS - set(platforms)
    extra_platforms = set(platforms) - EXPECTED_PLATFORMS
    for platform in sorted(missing_platforms):
        errors.append(f"platforms.{platform} is missing")
    for platform in sorted(extra_platforms):
        errors.append(f"platforms contains unexpected platform {platform}")

    for platform in sorted(EXPECTED_PLATFORMS & set(platforms)):
        entry = platforms[platform]
        if not isinstance(entry, dict):
            errors.append(f"platforms.{platform} must be an object")
            continue
        for field in ("runtime_source", "runtime_ref", "actual_mpv", "status"):
            if not isinstance(entry.get(field), str) or not entry[field].strip():
                errors.append(f"platforms.{platform}.{field} must be a non-empty string")
        status = entry.get("status")
        if status not in ALLOWED_PLATFORM_STATUS:
            errors.append(
                f"platforms.{platform}.status must be one of "
                f"{', '.join(sorted(ALLOWED_PLATFORM_STATUS))}"
            )
        if status == "upgraded" and entry.get("actual_mpv") != TARGET_TAG:
            errors.append(
                f"platforms.{platform} cannot be upgraded unless actual_mpv is {TARGET_TAG}"
            )

    pubspec_path = repo_root / "pubspec.yaml"
    lock_path = repo_root / "pubspec.lock"
    if not pubspec_path.is_file():
        errors.append("pubspec.yaml is missing")
    if not lock_path.is_file():
        errors.append("pubspec.lock is missing")

    if pubspec_path.is_file():
        pubspec_text = pubspec_path.read_text(encoding="utf-8")
        for package, expected_version in EXPECTED_MEDIA_KIT.items():
            constraint = _dependency_constraint(pubspec_text, package)
            if not _constraint_allows_version(constraint, expected_version):
                errors.append(
                    f"pubspec.yaml {package} must resolve from {expected_version}; "
                    f"found {constraint or 'missing'}"
                )

    if lock_path.is_file():
        lock_text = lock_path.read_text(encoding="utf-8")
        for package, expected_version in EXPECTED_MEDIA_KIT.items():
            locked = _locked_version(lock_text, package)
            if locked != expected_version:
                errors.append(
                    f"pubspec.lock {package} must be {expected_version}; "
                    f"found {locked or 'missing'}"
                )

    return errors


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Verify AnimeWitcher mpv integration")
    parser.add_argument(
        "--require-target-headers",
        action="store_true",
        help="also require vendored mpv v0.41.0 headers to match upstream Git blobs",
    )
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parents[1]
    manifest_path = repo_root / "third_party" / "mpv" / "integration.json"
    if not manifest_path.is_file():
        print(f"ERROR: missing manifest: {manifest_path.relative_to(repo_root)}", file=sys.stderr)
        return 1

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: unable to read mpv integration manifest: {exc}", file=sys.stderr)
        return 1

    errors = validate_manifest(manifest, repo_root)
    if args.require_target_headers:
        errors.extend(validate_target_headers(manifest, repo_root))
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"target mpv: {manifest['target']['tag']}")
    print(
        f"renderer: {manifest['renderer']['primary']} "
        f"(fallback: {manifest['renderer']['fallback']})"
    )
    for platform in ("ios", "macos", "android", "windows"):
        entry = manifest["platforms"][platform]
        print(
            f"{platform}: {entry['status']} - {entry['runtime_source']} "
            f"{entry['runtime_ref']} -> mpv {entry['actual_mpv']}"
        )
    if args.require_target_headers:
        print("target headers: verified v0.41.0 upstream Git blobs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
