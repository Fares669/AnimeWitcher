#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from mpv_runtime.prepare_android_runtime import prepare_runtime, verify_runtime


ABIS = ("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
BASELINE = {
    "arm64-v8a": (
        "https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-arm64-v8a.jar",
        "83df25b61193af8fa815e373143ac9af",
    ),
    "armeabi-v7a": (
        "https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-armeabi-v7a.jar",
        "22e21526fefc0a2b8f17adbec9f57590",
    ),
    "x86": (
        "https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-x86.jar",
        "0d742b756dc9d1fcd84ea271d8b68f32",
    ),
    "x86_64": (
        "https://github.com/media-kit/libmpv-android-video-build/releases/download/v1.1.7/default-x86_64.jar",
        "6fa26bf0459b11f1c0b0dbc29e5b940d",
    ),
}


class AndroidRuntimeOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.pub_cache = self.root / "pub-cache"
        self.lock_dir = self.repo / "third_party/mpv"
        self.lock_dir.mkdir(parents=True)
        self.package = (
            self.pub_cache
            / "hosted/pub.dev/media_kit_libs_android_video-1.3.8/android"
        )
        self.package.mkdir(parents=True)
        self.gradle = self.package / "build.gradle"
        entries = []
        for abi in ("arm64-v8a", "armeabi-v7a", "x86_64", "x86"):
            url, md5 = BASELINE[abi]
            entries.append(
                f'            ["url": "{url}", "md5": "{md5}", '
                f'"destination": file("$buildDir/v1.1.7/default-{abi}.jar")]'
            )
        self.gradle.write_text(
            "def filesToDownload = [\n" + ",\n".join(entries) + "\n        ]\n",
            encoding="utf-8",
        )

        artifacts = {}
        for abi in ABIS:
            jar = self.root / f"runtime-{abi}.jar"
            jar.write_bytes(f"mpv-v0.41.0-{abi}".encode())
            artifacts[abi] = {
                "url": jar.as_uri(),
                "sha256": hashlib.sha256(jar.read_bytes()).hexdigest(),
            }
        (self.lock_dir / "android-runtime.lock.json").write_text(
            json.dumps(
                {
                    "target": {"mpv_tag": "v0.41.0"},
                    "artifacts": artifacts,
                }
            ),
            encoding="utf-8",
        )

    def test_prepare_patches_all_four_media_kit_runtime_jars(self):
        marker = prepare_runtime(repo_root=self.repo, pub_cache=self.pub_cache)
        self.assertEqual(marker["mpv_tag"], "v0.41.0")
        self.assertEqual(set(marker["artifacts"]), set(ABIS))

        text = self.gradle.read_text(encoding="utf-8")
        for abi in ABIS:
            entry = marker["artifacts"][abi]
            self.assertIn(entry["url"], text)
            self.assertIn(entry["md5"], text)
            self.assertNotIn(BASELINE[abi][0], text)
        self.assertEqual(
            verify_runtime(repo_root=self.repo, pub_cache=self.pub_cache), []
        )

    def test_rejects_hash_mismatch_without_mutating_gradle(self):
        lock_path = self.lock_dir / "android-runtime.lock.json"
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        lock["artifacts"]["arm64-v8a"]["sha256"] = "0" * 64
        lock_path.write_text(json.dumps(lock), encoding="utf-8")
        before = self.gradle.read_text(encoding="utf-8")

        with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
            prepare_runtime(repo_root=self.repo, pub_cache=self.pub_cache)
        self.assertEqual(self.gradle.read_text(encoding="utf-8"), before)

    def test_rejects_media_kit_gradle_drift(self):
        self.gradle.write_text(
            self.gradle.read_text(encoding="utf-8").replace("v1.1.7", "v1.2.0", 1),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(RuntimeError, "Gradle drift"):
            prepare_runtime(repo_root=self.repo, pub_cache=self.pub_cache)


if __name__ == "__main__":
    unittest.main()
