#!/usr/bin/env python3
from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/mpv-runtime-windows.yml"
VULKAN_PATCH = ROOT / "third_party/mpv/patches/windows-vulkan-loader.patch"


class WindowsMpvBuildContractTests(unittest.TestCase):
    def test_static_vulkan_initializer_declaration_matches_implementation(self) -> None:
        patch = VULKAN_PATCH.read_text(encoding="utf-8")
        self.assertIn(
            "-#if defined(_WIN32)\n"
            "+#if defined(LOADER_DYNAMIC_LIB)\n"
            " BOOL __stdcall loader_initialize(PINIT_ONCE InitOnce, PVOID Parameter, PVOID *Context);",
            patch,
        )

    def test_windows_ci_reuses_pinned_container_toolchain_instead_of_building_host_llvm(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(
            "ghcr.io/shinchiro/archlinux@sha256:e96fbcab07052b6173981cffca3828a07b2f469bd2c07bd43d514080dab78b9b",
            workflow,
        )
        self.assertIn("HOST_CLANG_VERSION: 22.1.8", workflow)
        self.assertIn(
            'grep -F "clang version ${HOST_CLANG_VERSION}" /tmp/host-clang-version.txt',
            workflow,
        )
        self.assertIn("ninja -C \"build_${BIT}\" llvm-download", workflow)
        self.assertIn("llvm-ranlib", workflow)
        self.assertIn('ninja -C "build_${BIT}" llvm-wrapper', workflow)
        self.assertIn('windres="$PWD/clang_root/bin/${TARGET_CPU}-w64-mingw32-windres"', workflow)
        self.assertIn('--preprocessor "$PWD/clang_root/bin/${TARGET_CPU}-w64-mingw32-clang"', workflow)
        self.assertIn('real_windres="$PWD/clang_root/bin/${TARGET_CPU}-w64-mingw32-windres-22"', workflow)
        self.assertIn('ln -sf "$PWD/clang_root/bin/llvm-rc" "\\$real_windres"', workflow)
        self.assertIn('exec "\\$real_windres"', workflow)
        self.assertIn('real_preprocessor="$PWD/clang_root/bin/${TARGET_CPU}-w64-mingw32-windres-preprocessor"', workflow)
        self.assertIn('-E -xc -DRC_INVOKED', workflow)
        self.assertIn('--preprocessor "\\$real_preprocessor"', workflow)
        self.assertNotIn('exec -a "$0"', workflow)
        self.assertNotIn("CPATH=", workflow)
        reuse_start = workflow.index("      - name: Reuse pinned container LLVM host compiler")
        reuse_end = workflow.index("\n      - name: Patch LLVM MinGW libc++ compatibility", reuse_start)
        self.assertIn("          TARGET_CPU: ${{ matrix.target }}", workflow[reuse_start:reuse_end])
        self.assertNotIn("ninja -C \"build_${BIT}\" llvm\n", workflow)


if __name__ == "__main__":
    unittest.main()
