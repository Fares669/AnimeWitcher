#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import io
import tarfile
import tempfile
import unittest
from pathlib import Path

from mpv_runtime.verify_apple_archive import verify_archive

HEADERS = {
    "client.h": b"client header\n",
    "render.h": b"render header\n",
    "render_gl.h": b"render gl header\n",
    "stream_cb.h": b"stream cb header\n",
}


def git_blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


class AppleArchiveVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.expected = {name: git_blob_sha(data) for name, data in HEADERS.items()}

    def make_archive(
        self,
        platform: str,
        *,
        version: bytes = b"mpv v0.41.0\0",
        corrupt_header: str | None = None,
        omit_slice: str | None = None,
    ) -> Path:
        slices = {
            "ios": ["ios-arm64", "ios-arm64_x86_64-simulator"],
            "macos": ["macos-arm64_x86_64"],
        }[platform]
        archive = self.root / f"{platform}.tar.gz"
        prefix = f"libmpv-xcframeworks_test_{platform}-universal-video-default/Mpv.xcframework"
        with tarfile.open(archive, "w:gz") as tf:
            for slice_name in slices:
                if slice_name == omit_slice:
                    continue
                framework = f"{prefix}/{slice_name}/Mpv.framework"
                binary_path = (
                    f"{framework}/Versions/A/Mpv" if platform == "macos" else f"{framework}/Mpv"
                )
                self.add_bytes(tf, binary_path, b"MACHO\0" + version + b"payload")
                header_root = (
                    f"{framework}/Versions/A/Headers" if platform == "macos" else f"{framework}/Headers"
                )
                for name, data in HEADERS.items():
                    if name == corrupt_header:
                        data += b"corrupt"
                    self.add_bytes(tf, f"{header_root}/{name}", data)
        return archive

    @staticmethod
    def add_bytes(tf: tarfile.TarFile, name: str, data: bytes) -> None:
        info = tarfile.TarInfo(name)
        info.size = len(data)
        tf.addfile(info, io.BytesIO(data))

    def test_accepts_ios_v041_binary_and_exact_headers(self):
        archive = self.make_archive("ios")
        self.assertEqual(
            verify_archive(archive, "ios", "v0.41.0", self.expected), []
        )

    def test_rejects_old_mpv_binary_even_when_framework_exists(self):
        archive = self.make_archive("ios", version=b"mpv v0.40.0\0")
        errors = verify_archive(archive, "ios", "v0.41.0", self.expected)
        self.assertTrue(any("does not identify as mpv v0.41.0" in error for error in errors), errors)

    def test_rejects_header_blob_mismatch(self):
        archive = self.make_archive("macos", corrupt_header="client.h")
        errors = verify_archive(archive, "macos", "v0.41.0", self.expected)
        self.assertTrue(any("client.h blob mismatch" in error for error in errors), errors)

    def test_rejects_missing_required_slice(self):
        archive = self.make_archive("ios", omit_slice="ios-arm64")
        errors = verify_archive(archive, "ios", "v0.41.0", self.expected)
        self.assertIn("missing required Mpv slice: ios-arm64", errors)


if __name__ == "__main__":
    unittest.main()
