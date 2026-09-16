#!/usr/bin/env python3
"""Align generated LLVM-MinGW C++ wrappers and OpenAL scanning with libc++."""

from __future__ import annotations

import argparse
import shlex
from pathlib import Path


CPP_WRAPPERS = ("clang++", "g++", "c++")
DIRECT_FLAGS_MARKER = " # AnimeWitcher: explicit libc++ compiler flags"
OPENAL_MODULES_MARKER = "# AnimeWitcher: disable OpenAL modules for wrapper-based cross compiler"
OPENAL_MODULES_SETTING = (
    'set(ALSOFT_ENABLE_MODULES OFF CACHE BOOL '
    '"Disable OpenAL C++20 modules for cross compiler wrapper compatibility" FORCE)'
)
OPENAL_PACKAGE_MODULE_FLAG = "        -DALSOFT_ENABLE_MODULES=OFF"
OPENAL_PACKAGE_SCAN_FLAG = "        -DCMAKE_CXX_SCAN_FOR_MODULES=OFF"
CLEANUP_GENERATOR_MARKER = "# AnimeWitcher: detached-safe cleanup comparison"
CLEANUP_COMPARE_BLOCK = (
    CLEANUP_GENERATOR_MARKER
    + "\n"
    + '    if("${git_tag}" MATCHES "^[0-9a-fA-F]{40}$")\n'
    + '        set(reset_compare_ref "HEAD")\n'
    + '    elseif("${git_remote_name}" STREQUAL "" AND NOT "${git_tag}" STREQUAL "")\n'
    + '        set(reset_compare_ref "HEAD")\n'
    + "    else()\n"
    + '        set(reset_compare_ref "@{u}")\n'
    + "    endif()\n"
)
CLEANUP_COMPARE_OLD = "git -C ${source_dir} rev-parse @{u})"
CLEANUP_COMPARE_NEW = "git -C ${source_dir} rev-parse ${reset_compare_ref})"


def _required_args(*, sysroot: Path, resource_dir: Path) -> list[str]:
    include_dir = sysroot / "include" / "c++" / "v1"
    return [
        "-resource-dir",
        str(resource_dir),
        "--rtlib=compiler-rt",
        "--unwindlib=libunwind",
        "-stdlib=libc++",
        "-isystem",
        str(include_dir),
    ]


def _patch_wrapper(path: Path, required_args: list[str]) -> bool:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to read generated compiler wrapper: {path}: {exc}") from exc
    if not text.startswith("#!/bin/bash\n"):
        raise RuntimeError(f"generated compiler wrapper has unexpected format: {path}")

    invocation = '"$CCACHE \\"$PROG\\"'  # retained for a useful error below
    lines = text.splitlines()
    invocation_index = next(
        (index for index, line in enumerate(lines) if line.startswith('$CCACHE "$PROG"')),
        None,
    )
    if invocation_index is None:
        raise RuntimeError(
            f"generated compiler wrapper has no compiler invocation: {path} ({invocation})"
        )

    # Keep the generated FLAGS assignments intact. Some builder versions wrap
    # those assignments in a conditional block; removing only their bodies
    # would leave an invalid shell script with a dangling `fi`. The direct
    # arguments below are the authoritative cross-compiler defaults.
    kept = lines
    invocation_index = next(
        index for index, line in enumerate(kept) if line.startswith('$CCACHE "$PROG"')
    )
    direct_args = shlex.join(required_args)
    invocation = kept[invocation_index]
    if DIRECT_FLAGS_MARKER in invocation:
        invocation = invocation.split(DIRECT_FLAGS_MARKER, 1)[0].rstrip()
        if not invocation.endswith(direct_args):
            raise RuntimeError(
                f"generated compiler wrapper has an invalid existing libc++ suffix: {path}"
            )
        invocation = invocation[: -len(direct_args)].rstrip()
    kept[invocation_index] = f"{invocation} {direct_args}{DIRECT_FLAGS_MARKER}"
    new_text = "\n".join(kept) + "\n"
    if new_text == text:
        return False
    try:
        path.write_text(new_text, encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to update generated compiler wrapper: {path}: {exc}") from exc
    return True


def _patch_openal_module_setting(path: Path) -> bool:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to read generated CMake toolchain: {path}: {exc}") from exc

    if OPENAL_MODULES_MARKER in text:
        if OPENAL_MODULES_SETTING not in text:
            raise RuntimeError(f"generated CMake toolchain has an invalid OpenAL module override: {path}")
        return False
    if "ALSOFT_ENABLE_MODULES" in text:
        raise RuntimeError(f"generated CMake toolchain already configures OpenAL modules: {path}")

    separator = "" if text.endswith("\n") else "\n"
    new_text = (
        text
        + separator
        + "\n"
        + OPENAL_MODULES_MARKER
        + "\n"
        + OPENAL_MODULES_SETTING
        + "\n"
    )
    try:
        path.write_text(new_text, encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to update generated CMake toolchain: {path}: {exc}") from exc
    return True


def _patch_openal_package(path: Path) -> bool:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to read OpenAL package definition: {path}: {exc}") from exc

    module_count = text.count(OPENAL_PACKAGE_MODULE_FLAG)
    scan_count = text.count(OPENAL_PACKAGE_SCAN_FLAG)
    if module_count == 1 and scan_count == 1:
        return False
    if module_count != 0 or scan_count != 0:
        raise RuntimeError(f"OpenAL package has a partial scanner override: {path}")

    anchor = "        -DALSOFT_TESTS=OFF\n"
    if text.count(anchor) != 1:
        raise RuntimeError(f"OpenAL package layout changed: expected one test-option anchor: {path}")

    replacement = (
        anchor
        + OPENAL_PACKAGE_MODULE_FLAG
        + "\n"
        + OPENAL_PACKAGE_SCAN_FLAG
        + "\n"
    )
    updated = text.replace(anchor, replacement, 1)
    try:
        path.write_text(updated, encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to update OpenAL package definition: {path}: {exc}") from exc
    return True


def _patch_cleanup_generator(path: Path) -> bool:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to read builder cleanup generator: {path}: {exc}") from exc

    if CLEANUP_GENERATOR_MARKER in text:
        if text.count(CLEANUP_GENERATOR_MARKER) != 1:
            raise RuntimeError(f"builder cleanup generator has duplicate detached-safe markers: {path}")
        if CLEANUP_COMPARE_BLOCK not in text or CLEANUP_COMPARE_NEW not in text:
            raise RuntimeError(f"builder cleanup generator has an invalid detached-safe override: {path}")
        if CLEANUP_COMPARE_OLD in text:
            raise RuntimeError(f"builder cleanup generator still compares against upstream: {path}")
        return False

    if "reset_compare_ref" in text:
        raise RuntimeError(f"builder cleanup generator already has an unknown compare-ref override: {path}")

    anchor = (
        '    if("${git_remote_name}" STREQUAL "" AND NOT "${git_tag}" STREQUAL "")\n'
        "        # GIT_REMOTE_NAME is not set when commit hash is specified\n"
        '        set(reset "")\n'
        '    elseif(NOT "${git_reset}" STREQUAL "")\n'
        '        set(reset "${git_reset}")\n'
        "    else()\n"
        '        set(reset "@{u}") # eg: origin/master\n'
        "    endif()\n"
    )
    if text.count(anchor) != 1:
        raise RuntimeError(f"builder cleanup generator layout changed: expected reset selection block: {path}")
    if text.count(CLEANUP_COMPARE_OLD) != 1:
        raise RuntimeError(f"builder cleanup generator layout changed: expected upstream comparison: {path}")

    updated = text.replace(anchor, anchor + "\n" + CLEANUP_COMPARE_BLOCK, 1)
    updated = updated.replace(CLEANUP_COMPARE_OLD, CLEANUP_COMPARE_NEW, 1)
    try:
        path.write_text(updated, encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"unable to update builder cleanup generator: {path}: {exc}") from exc
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

    toolchain_file = sysroot.parent / "toolchain.cmake"
    if not toolchain_file.is_file():
        raise RuntimeError(f"generated CMake toolchain is missing: {toolchain_file}")
    _patch_openal_module_setting(toolchain_file)

    builder_root = sysroot.parent.parent
    cmake = builder_root / "cmake"
    cleanup_generator = cmake / "custom_steps.cmake"
    if not cleanup_generator.is_file():
        raise RuntimeError(f"builder cleanup generator is missing: {cleanup_generator}")
    _patch_cleanup_generator(cleanup_generator)

    packages = builder_root / "packages"
    openal_package = packages / "openal-soft.cmake"
    if not openal_package.is_file():
        raise RuntimeError(f"OpenAL package definition is missing: {openal_package}")
    _patch_openal_package(openal_package)

    required = _required_args(sysroot=sysroot, resource_dir=resource_dir)
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
        invocation = next(
            (line for line in text.splitlines() if line.startswith('$CCACHE "$PROG"')),
            None,
        )
        if invocation is None or DIRECT_FLAGS_MARKER not in invocation:
            raise RuntimeError(f"failed to verify direct libc++ arguments in {path}")
        for argument in required:
            if argument not in invocation:
                raise RuntimeError(
                    f"failed to verify generated wrapper argument in {path}: {argument}"
                )

    toolchain_text = toolchain_file.read_text(encoding="utf-8")
    if toolchain_text.count(OPENAL_MODULES_MARKER) != 1 or toolchain_text.count(
        OPENAL_MODULES_SETTING
    ) != 1:
        raise RuntimeError(f"failed to verify OpenAL module override in {toolchain_file}")

    cleanup_text = cleanup_generator.read_text(encoding="utf-8")
    if cleanup_text.count(CLEANUP_GENERATOR_MARKER) != 1:
        raise RuntimeError(f"failed to verify detached-safe cleanup generator in {cleanup_generator}")
    if CLEANUP_COMPARE_BLOCK not in cleanup_text or CLEANUP_COMPARE_NEW not in cleanup_text:
        raise RuntimeError(f"failed to verify cleanup compare ref in {cleanup_generator}")
    if CLEANUP_COMPARE_OLD in cleanup_text:
        raise RuntimeError(f"cleanup generator still contains unsafe upstream comparison: {cleanup_generator}")

    openal_text = openal_package.read_text(encoding="utf-8")
    if openal_text.count(OPENAL_PACKAGE_MODULE_FLAG) != 1 or openal_text.count(
        OPENAL_PACKAGE_SCAN_FLAG
    ) != 1:
        raise RuntimeError(f"failed to verify OpenAL dependency scanner override in {openal_package}")
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
