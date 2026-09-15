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
        self.assertIn("Patch pinned-source cleanup for detached commits", workflow)
        self.assertIn("Pin graphengine and zimg source mirrors", workflow)
        self.assertIn("Pin OpenSSL and HarfBuzz source commits", workflow)
        self.assertIn("OPENSSL_COMMIT: 98acb6b02839c609ef5b837794e08d906d965335", workflow)
        self.assertIn("HARFBUZZ_COMMIT: 4e3df1c1383481ed5717603d5dd3453a04fb16ba", workflow)
        self.assertIn('grep -F "GIT_TAG $OPENSSL_COMMIT" packages/openssl.cmake', workflow)
        self.assertIn('grep -F "GIT_TAG $HARFBUZZ_COMMIT" packages/harfbuzz.cmake', workflow)
        self.assertIn("https://github.com/sekrit-twc/graphengine.git", workflow)
        self.assertIn("GIT_TAG 91c6af4c795c5396d8b974f24b4d2e2ecca04e2d", workflow)
        self.assertIn("https://github.com/sekrit-twc/zimg.git", workflow)
        self.assertIn("GIT_TAG 67e0603271c080e22c8429856dd4a8a56587e61e", workflow)
        self.assertIn("packages/graphengine-prefix/src/graphengine-stamp/reset_head.sh", workflow)
        self.assertIn("packages/libzimg-prefix/src/libzimg-stamp/reset_head.sh", workflow)
        self.assertIn("if old in text:", workflow)
        self.assertIn('grep -F \'reset --hard\' "$reset_script"', workflow)
        self.assertIn("if old in text:", workflow)
        self.assertIn('grep -F \'reset --hard\' "$reset_script"', workflow)
        self.assertIn(
            '"build_${BIT}/toolchain/cppwinrt-prefix/src/cppwinrt-stamp/reset_head.sh"',
            workflow,
        )
        self.assertIn(
            '"build_${BIT}/packages/openssl-prefix/src/openssl-stamp/reset_head.sh"',
            workflow,
        )
        self.assertIn(
            '"build_${BIT}/packages/harfbuzz-prefix/src/harfbuzz-stamp/reset_head.sh"',
            workflow,
        )
        self.assertIn(
            '"build_${BIT}/packages/vulkan-prefix/src/vulkan-stamp/reset_head.sh" <<\\'PY\\'',
            workflow,
        )
        self.assertIn(
            '"build_${BIT}/packages/vulkan-prefix/src/vulkan-stamp/reset_head.sh"',
            workflow,
        )
        self.assertIn(
            'FLAGS="$FLAGS -resource-dir @CMAKE_INSTALL_PREFIX@/lib/clang/20"',
            workflow,
        )
        self.assertIn('host_resource_dir="$(clang -print-resource-dir)"', workflow)
        self.assertIn(
            'ln -sfn "$host_resource_dir/include" "$PWD/clang_root/lib/clang/20/include"',
            workflow,
        )
        self.assertIn("llvm-ranlib", workflow)
        self.assertIn('ninja -C "build_${BIT}" llvm-wrapper', workflow)
        self.assertIn('windres="$PWD/clang_root/bin/${TARGET_CPU}-w64-mingw32-windres"', workflow)
        self.assertIn('exec "$PWD/clang_root/bin/${TARGET_CPU}-w64-mingw32-clang" -E -xc -DRC_INVOKED', workflow)
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
