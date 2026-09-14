#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/mpv_runtime/android_ndk_tools.sh"


class AndroidNdkToolLookupTests(unittest.TestCase):
    def test_resolves_executable_symlink_in_ndk_r29(self):
        with tempfile.TemporaryDirectory() as temp:
            sdk = Path(temp)
            bin_dir = sdk / "ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64/bin"
            bin_dir.mkdir(parents=True)
            target = sdk / "real-llvm-strip"
            target.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            target.chmod(0o755)
            (bin_dir / "llvm-strip").symlink_to(target)
            command = (
                f"source {HELPER!s}; "
                f"find_android_ndk_llvm_tool {sdk!s} llvm-strip"
            )
            result = subprocess.run(
                ["bash", "-c", command], text=True, capture_output=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(result.stdout.strip()), bin_dir / "llvm-strip")

    def test_rejects_missing_tool(self):
        with tempfile.TemporaryDirectory() as temp:
            sdk = Path(temp)
            (sdk / "ndk/29.0.14206865").mkdir(parents=True)
            command = (
                f"source {HELPER!s}; "
                f"find_android_ndk_llvm_tool {sdk!s} llvm-strip"
            )
            result = subprocess.run(
                ["bash", "-c", command], text=True, capture_output=True, check=False
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("llvm-strip not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
