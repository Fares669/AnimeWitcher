#!/usr/bin/env python3
"""Make generated LLVM-MinGW C++ wrappers use the installed libc++ runtime."""

from __future__ import annotations

import argparse
import shlex
from pathlib import Path


CPP_WRAPPERS = ("clang++", "g++", "c++")


def _required_lines(*, sysroot: Path, resource_dir: Path) -> list[str]:
    include_dir = sysroot / "include" / "c++" / "v1"
    return [
        f'FLAGS="$FLAGS -resource-dir {shlex.quote(str(resource_dir))}"',
        'FLAGS="$FLAGS --rtlib=compiler-rt --unwindlib=libunwind"',
        'FLAGS="$FLAGS -stdlib=libc++"',
        f'FLAGS="$FLAGS -isystem {shlex.quote(str(include_dir))}"',
    ]


def _patch_wrapper(path: Path, required_lines: list[str]) -> bool:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to read generated compiler wrapper: {path}: {exc}") from exc
    if not text.startswith("#!/bin/bash\n"):
        raise RuntimeError(f"generated compiler wrapper has unexpected format: {path}")

    invocation = '"$CCACHE \"$PROG\"'  # retained for a useful error below
    lines = text.splitlines()
    invocation_index = next(
        (index for index, line in enumerate(lines) if line.startswith("$CCACHE \"$PROG\"")),
        None,
    )
    if invocation_index is None:
        raise RuntimeError(
            f"generated compiler wrapper has no compiler invocation: {path} ({invocation})"
        )

    # Replace prior copies so rerunning this helper is deterministic even when
    # a partially patched wrapper was left by an interrupted CI job. Keep
    # unrelated FLAGS assignments such as --sysroot and optimization flags.
    required_prefixes = (
        'FLAGS="$FLAGS -resource-dir ',
        'FLAGS="$FLAGS --rtlib=',
        'FLAGS="$FLAGS -stdlib=',
        'FLAGS="$FLAGS -isystem ',
    )
    kept = [
        line
        for line in lines
        if not any(line.startswith(prefix) for prefix in required_prefixes)
    ]
    invocation_index = next(
        index for index, line in enumerate(kept) if line.startswith("$CCACHE \"$PROG\"")
    )
    patched = kept[:invocation_index] + required_lines + kept[invocation_index:]
    new_text = "\n".join(patched) + "\n"
    if new_text == text:
        return False
    try:
        path.write_text(new_text, encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to update generated compiler wrapper: {path}: {exc}") from exc
    return True


def patch_wrappers(
    *,
    bin_dir: Path,
    sysroot: Path,
    resource_dir: Path,
    target_prefix: str,
) -> list[str]:
    include_dir = sysroot / "include" / "c++" / "v1"
    if not include_dir.is_dir():
        raise RuntimeError(f"libc++ headers are missing: {include_dir}")
    if not resource_dir.is_dir():
        raise RuntimeError(f"Clang resource directory is missing: {resource_dir}")
    if not bin_dir.is_dir():
        raise RuntimeError(f"compiler wrapper directory is missing: {bin_dir}")

    required = _required_lines(sysroot=sysroot, resource_dir=resource_dir)
    changed: list[str] = []
    for compiler in CPP_WRAPPERS:
        path = bin_dir / f"{target_prefix}-{compiler}"
        if not path.is_file():
            raise RuntimeError(f"generated C++ compiler wrapper is missing: {path}")
        if _patch_wrapper(path, required):
            changed.append(path.name)

    for compiler in CPP_WRAPPERS:
        path = bin_dir / f"{target_prefix}-{compiler}"
        text = path.read_text(encoding="utf-8")
        for line in required:
            if line not in text:
                raise RuntimeError(f"failed to verify generated wrapper flag in {path}: {line}")
    return changed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--sysroot", type=Path, required=True)
    parser.add_argument("--resource-dir", type=Path, required=True)
    parser.add_argument("--target-prefix", required=True)
    args = parser.parse_args(argv)
    try:
        changed = patch_wrappers(
            bin_dir=args.bin_dir,
            sysroot=args.sysroot,
            resource_dir=args.resource_dir,
            target_prefix=args.target_prefix,
        )
    except RuntimeError as exc:
        print(f"ERROR: {exc}")
        return 1
    print("patched Windows C++ compiler wrappers: " + (", ".join(changed) if changed else "already aligned"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
