#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from mpv_runtime.prepare_windows_runtime import prepare_runtime, verify_runtime


BASELINE_URL = "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20241021/mpv-dev-x86_64-20241021-git-0f78584.7z"
BASELINE_MD5 = "d82e6f02f290d391e9aa30121ace8ec8"


class WindowsRuntimeOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.pub_cache = self.root / "pub-cache"
        lock_dir = self.repo / "third_party/mpv"
        lock_dir.mkdir(parents=True)

        self.package = (
            self.pub_cache
            / "hosted/pub.dev/media_kit_libs_windows_video-1.0.11/windows"
        )
        self.package.mkdir(parents=True)
        self.cmake = self.package / "CMakeLists.txt"
        self.cmake.write_text(
            'cmake_minimum_required(VERSION 3.14)\n'
            'set(LIBMPV_VERSION "20241021" CACHE STRING "libmpv version")\n'
            f'set(LIBMPV_URL "{BASELINE_URL}")\n'
            f'set(LIBMPV_MD5 "{BASELINE_MD5}")\n'
            'file(DOWNLOAD ${LIBMPV_URL} ${LIBMPV_FILE} EXPECTED_MD5 ${LIBMPV_MD5})\n',
            encoding="utf-8",
        )

        dll = self.root / "libmpv-2.dll"
        dll.write_bytes(b"MZ" + b"animewitcher-mpv-v0.41.0-x64")
        digest = hashlib.sha256(dll.read_bytes()).hexdigest()
        (lock_dir / "windows-runtime.lock.json").write_text(
            json.dumps(
                {
                    "target": {"mpv_tag": "v0.41.0"},
                    "artifact": {
                        "url": dll.as_uri(),
                        "sha256": digest,
                        "filename": "libmpv-2.dll",
                    },
                }
            ),
            encoding="utf-8",
        )

    def test_prepare_pins_exact_runtime_and_stages_override_dll(self):
        marker = prepare_runtime(repo_root=self.repo, pub_cache=self.pub_cache)
        self.assertEqual(marker["mpv_tag"], "v0.41.0")
        self.assertTrue((self.repo / "third_party/mpv/shinchiro/libmpv-2.dll").is_file())
        self.assertEqual(
            verify_runtime(repo_root=self.repo, pub_cache=self.pub_cache), []
        )

    def test_rejects_hash_mismatch_before_mutating_package(self):
        lock_path = self.repo / "third_party/mpv/windows-runtime.lock.json"
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        lock["artifact"]["sha256"] = "0" * 64
        lock_path.write_text(json.dumps(lock), encoding="utf-8")
        before = self.cmake.read_text(encoding="utf-8")

        with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
            prepare_runtime(repo_root=self.repo, pub_cache=self.pub_cache)
        self.assertEqual(self.cmake.read_text(encoding="utf-8"), before)
        self.assertFalse((self.repo / "third_party/mpv/shinchiro/libmpv-2.dll").exists())

    def test_rejects_media_kit_cmake_drift(self):
        self.cmake.write_text(
            self.cmake.read_text(encoding="utf-8").replace("20241021", "20250101", 1),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(RuntimeError, "CMake drift"):
            prepare_runtime(repo_root=self.repo, pub_cache=self.pub_cache)


if __name__ == "__main__":
    unittest.main()
