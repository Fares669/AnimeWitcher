#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

from mpv_runtime.prepare_apple_runtime import prepare_runtime, verify_runtime


class AppleRuntimeOverlayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.pub_cache = self.root / "pub-cache"
        self.repo = self.root / "repo"
        lock_dir = self.repo / "third_party/mpv"
        lock_dir.mkdir(parents=True)
        (lock_dir / "darwin-runtime.lock.json").write_text(
            json.dumps({"target": {"mpv_tag": "v0.41.0"}}), encoding="utf-8"
        )

    def make_package(self, platform: str) -> Path:
        spec = {
            "ios": (
                "media_kit_libs_ios_video-1.1.4",
                "a0dbcddc0eaefa5534eb2bdc797e5386b1e0cd4057ed8f73aa2dd6105503dffb",
            ),
            "macos": (
                "media_kit_libs_macos_video-1.1.4",
                "dd9928fff9c97329e17f69fe8ef0d621cf458f9f70847955f84b4eb1e9047b09",
            ),
        }[platform]
        package = self.pub_cache / "hosted/pub.dev" / spec[0] / platform
        package.mkdir(parents=True)
        (package / "Makefile").write_text(
            "all: Frameworks/*.xcframework\n\n"
            "MPV_XCFRAMEWORKS_VERSION=v0.7.2\n"
            f"MPV_XCFRAMEWORKS_SHA256SUM={spec[1]}\n\n"
            f".cache/xcframeworks/libmpv-xcframeworks-${{MPV_XCFRAMEWORKS_VERSION}}-{platform}-universal.tar.gz:\n"
            "\tmkdir -p .cache/xcframeworks\n",
            encoding="utf-8",
        )
        return package

    def make_archive(self) -> tuple[Path, str]:
        archive = self.root / "runtime.tar.gz"
        payload = b"fake framework payload"
        with tarfile.open(archive, "w:gz") as tf:
            info = tarfile.TarInfo("Mpv.xcframework/Info.plist")
            info.size = len(payload)
            tf.addfile(info, io.BytesIO(payload))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        return archive, digest

    def test_prepare_and_verify_ios_overlay(self):
        package = self.make_package("ios")
        archive, digest = self.make_archive()
        marker = prepare_runtime(
            repo_root=self.repo,
            pub_cache=self.pub_cache,
            platform="ios",
            archive=archive,
            expected_sha256=digest,
            overlay_version="v0.41.0-animewitcher.1",
        )
        self.assertEqual(marker["mpv_tag"], "v0.41.0")
        text = (package / "Makefile").read_text(encoding="utf-8")
        self.assertIn("MPV_XCFRAMEWORKS_VERSION=v0.41.0-animewitcher.1", text)
        self.assertIn(f"MPV_XCFRAMEWORKS_SHA256SUM={digest}", text)
        errors = verify_runtime(
            repo_root=self.repo,
            pub_cache=self.pub_cache,
            platform="ios",
        )
        self.assertEqual(errors, [])

    def test_rejects_hash_mismatch_before_mutating_package(self):
        package = self.make_package("ios")
        before = (package / "Makefile").read_text(encoding="utf-8")
        archive, _ = self.make_archive()
        with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
            prepare_runtime(
                repo_root=self.repo,
                pub_cache=self.pub_cache,
                platform="ios",
                archive=archive,
                expected_sha256="0" * 64,
                overlay_version="v0.41.0-animewitcher.1",
            )
        self.assertEqual((package / "Makefile").read_text(encoding="utf-8"), before)

    def test_rejects_upstream_makefile_drift(self):
        package = self.make_package("macos")
        makefile = package / "Makefile"
        makefile.write_text(makefile.read_text().replace("v0.7.2", "v0.8.0"), encoding="utf-8")
        archive, digest = self.make_archive()
        with self.assertRaisesRegex(RuntimeError, "Makefile drift"):
            prepare_runtime(
                repo_root=self.repo,
                pub_cache=self.pub_cache,
                platform="macos",
                archive=archive,
                expected_sha256=digest,
                overlay_version="v0.41.0-animewitcher.1",
            )

    def test_rejects_archive_without_mpv_xcframework(self):
        self.make_package("ios")
        archive = self.root / "bad.tar.gz"
        with tarfile.open(archive, "w:gz") as tf:
            payload = b"x"
            info = tarfile.TarInfo("NotMpv.framework/file")
            info.size = len(payload)
            tf.addfile(info, io.BytesIO(payload))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        with self.assertRaisesRegex(RuntimeError, "Mpv.xcframework"):
            prepare_runtime(
                repo_root=self.repo,
                pub_cache=self.pub_cache,
                platform="ios",
                archive=archive,
                expected_sha256=digest,
                overlay_version="v0.41.0-animewitcher.1",
            )


if __name__ == "__main__":
    unittest.main()
