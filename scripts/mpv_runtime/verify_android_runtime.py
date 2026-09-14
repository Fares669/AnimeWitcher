#!/usr/bin/env python3
"""Verify that the Android media_kit runtime JARs actually bundle mpv v0.41.0."""

from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path

TARGET_VERSION = "0.41.0"
TARGET_TAG = f"v{TARGET_VERSION}"
EXPECTED_ABIS = ("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
VERSION_PATTERN = re.compile(
    rb"mpv[^\x00\n\r]{0,32}v?0\.41\.0(?:[^0-9]|$)", re.IGNORECASE
)


def _parse_jar(value: str) -> tuple[str, Path]:
    abi, separator, raw_path = value.partition("=")
    if not separator or abi not in EXPECTED_ABIS or not raw_path:
        raise argparse.ArgumentTypeError(
            "--jar must be ABI=PATH where ABI is one of " + ", ".join(EXPECTED_ABIS)
        )
    return abi, Path(raw_path)


def _candidate_entries(archive: zipfile.ZipFile, abi: str) -> list[str]:
    suffix = f"/{abi}/libmpv.so"
    return [
        name
        for name in archive.namelist()
        if name == f"jni/{abi}/libmpv.so"
        or name == f"lib/{abi}/libmpv.so"
        or name.endswith(suffix)
    ]


def verify_jar(abi: str, path: Path) -> list[str]:
    errors: list[str] = []
    if not path.is_file():
        return [f"{abi}: JAR does not exist: {path}"]

    try:
        with zipfile.ZipFile(path) as archive:
            candidates = _candidate_entries(archive, abi)
            if len(candidates) != 1:
                if not candidates:
                    errors.append(
                        f"{abi}: JAR must contain libmpv.so for {abi}; none was found"
                    )
                else:
                    errors.append(
                        f"{abi}: JAR contains multiple libmpv.so entries for {abi}: "
                        + ", ".join(candidates)
                    )
                return errors

            payload = archive.read(candidates[0])
    except (OSError, zipfile.BadZipFile, KeyError) as exc:
        return [f"{abi}: unable to inspect {path}: {exc}"]

    if not payload.startswith(b"\x7fELF"):
        errors.append(f"{abi}: bundled libmpv.so is not an ELF binary")
        return errors

    if VERSION_PATTERN.search(payload) is None:
        errors.append(
            f"{abi}: bundled libmpv.so does not identify as mpv {TARGET_TAG}"
        )
    return errors


def verify(jars: dict[str, Path]) -> list[str]:
    errors: list[str] = []
    for abi in EXPECTED_ABIS:
        path = jars.get(abi)
        if path is None:
            errors.append(f"{abi}: required runtime JAR was not supplied")
            continue
        errors.extend(verify_jar(abi, path))
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify Android media_kit JARs bundle mpv v0.41.0"
    )
    parser.add_argument(
        "--jar",
        action="append",
        type=_parse_jar,
        default=[],
        metavar="ABI=PATH",
        help="runtime JAR for one Android ABI; supply all four supported ABIs",
    )
    args = parser.parse_args(argv)

    jars: dict[str, Path] = {}
    for abi, path in args.jar:
        if abi in jars:
            print(f"ERROR: {abi}: duplicate --jar argument", file=sys.stderr)
            return 1
        jars[abi] = path

    errors = verify(jars)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"android mpv runtime: {TARGET_TAG}")
    print("abis: " + ", ".join(EXPECTED_ABIS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
