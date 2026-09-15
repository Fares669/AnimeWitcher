#!/usr/bin/env python3
"""Verify that bundled Windows libmpv DLLs identify as mpv v0.41.0."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

TARGET_VERSION = "0.41.0"
TARGET_TAG = f"v{TARGET_VERSION}"
EXPECTED_ARCHES = ("x64", "arm64")
VERSION_PATTERN = re.compile(
    rb"mpv[^\x00\n\r]{0,32}v?0\.41\.0(?:[^0-9]|$)", re.IGNORECASE
)


def _parse_dll(value: str) -> tuple[str, Path]:
    arch, separator, raw_path = value.partition("=")
    if not separator or arch not in EXPECTED_ARCHES or not raw_path:
        raise argparse.ArgumentTypeError(
            "--dll must be ARCH=PATH where ARCH is one of "
            + ", ".join(EXPECTED_ARCHES)
        )
    return arch, Path(raw_path)


def verify_dll(arch: str, path: Path) -> list[str]:
    if not path.is_file():
        return [f"{arch}: DLL does not exist: {path}"]

    try:
        payload = path.read_bytes()
    except OSError as exc:
        return [f"{arch}: unable to read {path}: {exc}"]

    errors: list[str] = []
    if not payload.startswith(b"MZ"):
        errors.append(f"{arch}: bundled libmpv DLL is not a PE binary")
        return errors

    if VERSION_PATTERN.search(payload) is None:
        errors.append(f"{arch}: bundled libmpv DLL does not identify as mpv {TARGET_TAG}")
    return errors


def verify(dlls: dict[str, Path]) -> list[str]:
    errors: list[str] = []
    for arch in EXPECTED_ARCHES:
        path = dlls.get(arch)
        if path is None:
            errors.append(f"{arch}: required libmpv DLL was not supplied")
            continue
        errors.extend(verify_dll(arch, path))
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify Windows media_kit libmpv DLLs bundle mpv v0.41.0"
    )
    parser.add_argument(
        "--dll",
        action="append",
        type=_parse_dll,
        default=[],
        metavar="ARCH=PATH",
        help="libmpv-2.dll for one architecture; supply x64 and arm64",
    )
    args = parser.parse_args(argv)

    dlls: dict[str, Path] = {}
    for arch, path in args.dll:
        if arch in dlls:
            print(f"ERROR: {arch}: duplicate --dll argument", file=sys.stderr)
            return 1
        dlls[arch] = path

    errors = verify(dlls)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"windows mpv runtime: {TARGET_TAG}")
    print("architectures: " + ", ".join(EXPECTED_ARCHES))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
