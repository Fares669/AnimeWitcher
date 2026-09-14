#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts/prepare_media_kit_ios_headers.sh"


class PrepareMediaKitIosHeadersTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.pub_cache = Path(self.temp.name) / "pub-cache"
        (self.root / "scripts").mkdir(parents=True)
        (self.root / "third_party/mpv/v0.41.0").mkdir(parents=True)
        shutil.copy2(SCRIPT, self.root / "scripts/prepare_media_kit_ios_headers.sh")
        shutil.copy2(
            REPO_ROOT / "third_party/mpv/integration.json",
            self.root / "third_party/mpv/integration.json",
        )
        shutil.copy2(
            REPO_ROOT / "third_party/mpv/darwin-runtime.lock.json",
            self.root / "third_party/mpv/darwin-runtime.lock.json",
        )
        for name in ("client.h", "render.h", "render_gl.h", "stream_cb.h"):
            shutil.copy2(
                REPO_ROOT / f"third_party/mpv/v0.41.0/{name}",
                self.root / f"third_party/mpv/v0.41.0/{name}",
            )

        self.video_package = (
            self.pub_cache / "hosted/pub.dev/media_kit_video-2.0.1"
        )
        makefile_dir = self.video_package / "common/darwin"
        makefile_dir.mkdir(parents=True)
        self.makefile = makefile_dir / "Makefile"
        self.makefile.write_text(
            "all: headers\n\n"
            "MPV_HEADERS_VERSION=v0.36.0\n"
            "MPV_HEADERS_SHA256SUM=29abc44f8ebee013bb2f9fe14d80b30db19b534c679056e4851ceadf5a5e8bf6\n",
            encoding="utf-8",
        )

        self.runtime_package = (
            self.pub_cache / "hosted/pub.dev/media_kit_libs_ios_video-1.1.4/ios"
        )
        self.runtime_package.mkdir(parents=True)

    def run_script(self) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PUB_CACHE"] = str(self.pub_cache)
        return subprocess.run(
            ["bash", str(self.root / "scripts/prepare_media_kit_ios_headers.sh")],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def write_runtime_marker(self, *, mpv_tag: str = "v0.41.0") -> None:
        lock = json.loads(
            (self.root / "third_party/mpv/darwin-runtime.lock.json").read_text(
                encoding="utf-8"
            )
        )
        artifact = lock["artifacts"]["ios"]
        marker = {
            "schema_version": 1,
            "platform": "ios",
            "package": "media_kit_libs_ios_video",
            "package_version": "1.1.4",
            "mpv_tag": mpv_tag,
            "overlay_version": artifact["overlay_version"],
            "sha256": artifact["sha256"],
            "source_url": artifact["url"],
            "cache_file": "runtime.tar.gz",
        }
        (self.runtime_package / ".animewitcher-mpv-runtime.json").write_text(
            json.dumps(marker), encoding="utf-8"
        )

    def test_rejects_header_activation_without_verified_runtime_marker(self):
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime overlay marker is missing", result.stderr)
        self.assertIn("MPV_HEADERS_VERSION=v0.36.0", self.makefile.read_text())

    def test_rejects_marker_for_old_runtime(self):
        self.write_runtime_marker(mpv_tag="v0.36.0")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runtime marker does not match pinned mpv v0.41.0", result.stderr)

    def test_activates_exact_v041_headers_after_runtime_alignment(self):
        self.write_runtime_marker()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)

        headers = self.video_package / "ios/Headers/mpv"
        for name in ("client.h", "render.h", "render_gl.h", "stream_cb.h"):
            self.assertEqual(
                (headers / name).read_bytes(),
                (self.root / f"third_party/mpv/v0.41.0/{name}").read_bytes(),
            )
        text = self.makefile.read_text(encoding="utf-8")
        self.assertNotIn("MPV_HEADERS_VERSION=v0.36.0", text)
        self.assertIn("already pinned local headers", text)


if __name__ == "__main__":
    unittest.main()
