#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "mpv_runtime" / "patch_windows_compiler_wrappers.py"


def _load_helper():
    spec = importlib.util.spec_from_file_location("patch_windows_compiler_wrappers", HELPER)
    if spec is None or spec.loader is None:
        raise AssertionError(f"unable to load helper: {HELPER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class WindowsCompilerWrapperPatchTests(unittest.TestCase):
    def test_adds_libcxx_flags_and_is_idempotent(self):
        self.assertTrue(HELPER.is_file(), f"missing wrapper patch helper: {HELPER}")
        helper = _load_helper()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bin_dir = root / "bin"
            sysroot = root / "sysroot"
            resource_dir = root / "clang_root" / "lib" / "clang" / "20"
            (sysroot / "include" / "c++" / "v1").mkdir(parents=True)
            resource_dir.mkdir(parents=True)
            bin_dir.mkdir()
            for compiler in ("clang++", "g++", "c++"):
                (bin_dir / f"x86_64-w64-mingw32-{compiler}").write_text(
                    "#!/bin/bash\n"
                    "PROG=/clang_root/bin/clang++\n"
                    "FLAGS=\"$FLAGS --sysroot /old/sysroot\"\n"
                    "$CCACHE \"$PROG\" \"$@\" $FLAGS\n",
                    encoding="utf-8",
                )

            changed = helper.patch_wrappers(
                bin_dir=bin_dir,
                sysroot=sysroot,
                resource_dir=resource_dir,
                target_prefix="x86_64-w64-mingw32",
            )
            self.assertEqual(
                changed,
                [
                    "x86_64-w64-mingw32-clang++",
                    "x86_64-w64-mingw32-g++",
                    "x86_64-w64-mingw32-c++",
                ],
            )
            wrapper = bin_dir / "x86_64-w64-mingw32-g++"
            patched = wrapper.read_text(encoding="utf-8")
            self.assertIn('FLAGS="$FLAGS -stdlib=libc++"', patched)
            self.assertIn(
                f'FLAGS="$FLAGS -isystem {sysroot / "include/c++/v1"}"',
                patched,
            )
            self.assertIn(
                f'FLAGS="$FLAGS -resource-dir {resource_dir}"',
                patched,
            )
            self.assertIn(
                'FLAGS="$FLAGS --rtlib=compiler-rt --unwindlib=libunwind"',
                patched,
            )

            self.assertEqual(
                helper.patch_wrappers(
                    bin_dir=bin_dir,
                    sysroot=sysroot,
                    resource_dir=resource_dir,
                    target_prefix="x86_64-w64-mingw32",
                ),
                [],
            )
            self.assertEqual(wrapper.read_text(encoding="utf-8"), patched)

    def test_rejects_missing_libcxx_headers(self):
        self.assertTrue(HELPER.is_file(), f"missing wrapper patch helper: {HELPER}")
        helper = _load_helper()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(RuntimeError, "libc\\+\\+ headers"):
                helper.patch_wrappers(
                    bin_dir=root / "bin",
                    sysroot=root / "sysroot",
                    resource_dir=root / "resource",
                    target_prefix="x86_64-w64-mingw32",
                )


if __name__ == "__main__":
    unittest.main()
