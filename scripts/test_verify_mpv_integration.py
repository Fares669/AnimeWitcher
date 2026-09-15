#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
VERIFIER_PATH = REPO_ROOT / "scripts" / "verify_mpv_integration.py"
MANIFEST_PATH = REPO_ROOT / "third_party" / "mpv" / "integration.json"

APPROVED_HEADERS = {
    "client.h": "85cff63bd5d20797ca622834fd904d506d0d4fd8",
    "render.h": "99aadeb5d837dd47a8a170ae55672cf46ec5f4c4",
    "render_gl.h": "aa2719d5c4ebfa1ecaee469b563d138e10b1df4e",
    "stream_cb.h": "9ae6f31a16847d9a695886a78bc1b7a2c9942a27",
}


def load_verifier():
    spec = importlib.util.spec_from_file_location("verify_mpv_integration", VERIFIER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def valid_manifest():
    return {
        "target": {
            "tag": "v0.41.0",
            "headers": APPROVED_HEADERS.copy(),
        },
        "renderer": {
            "primary": "gpu-next",
            "fallback": "gpu",
        },
        "media_kit": {
            "media_kit": "1.2.6",
            "media_kit_video": "2.0.1",
            "media_kit_libs_video": "1.0.7",
        },
        "platforms": {
            "ios": {
                "runtime_source": "libmpv-darwin-build",
                "runtime_ref": "v0.6.0",
                "actual_mpv": "v0.36.0",
                "status": "pending",
            },
            "macos": {
                "runtime_source": "libmpv-darwin-build",
                "runtime_ref": "v0.6.0",
                "actual_mpv": "v0.36.0",
                "status": "pending",
            },
            "android": {
                "runtime_source": "libmpv-android-video-build",
                "runtime_ref": "v1.1.7",
                "actual_mpv": "78d43740f52db817d98bcf24fb30a76ab6fa13ff",
                "status": "pending",
            },
            "windows": {
                "runtime_source": "media_kit_libs_windows_video",
                "runtime_ref": "2023-09-24",
                "actual_mpv": "652a1dd90711839acdccc08004056d25514ef2d8",
                "status": "pending",
            },
        },
    }


def write_dependency_fixture(root: Path):
    (root / "pubspec.yaml").write_text(
        "\n".join(
            [
                "dependencies:",
                "  media_kit: ^1.2.6",
                "  media_kit_video: ^2.0.1",
                "  media_kit_libs_video: ^1.0.7",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    (root / "pubspec.lock").write_text(
        "\n".join(
            [
                "packages:",
                "  media_kit:",
                "    dependency: direct main",
                "    version: \"1.2.6\"",
                "  media_kit_video:",
                "    dependency: direct main",
                "    version: \"2.0.1\"",
                "  media_kit_libs_video:",
                "    dependency: direct main",
                "    version: \"1.0.7\"",
            ]
        )
        + "\n",
        encoding="utf-8",
    )


class VerifierAvailabilityTest(unittest.TestCase):
    def test_verifier_exists_before_contract_can_pass(self):
        self.assertTrue(
            VERIFIER_PATH.is_file(),
            "mpv integration verifier has not been implemented yet",
        )


@unittest.skipUnless(VERIFIER_PATH.is_file(), "verifier not implemented yet")
class IntegrationContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.verifier = load_verifier()

    def validate(self, manifest):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            write_dependency_fixture(root)
            return self.verifier.validate_manifest(manifest, root)

    def test_accepts_exact_target_renderer_dependencies_and_pending_inventory(self):
        self.assertEqual(self.validate(valid_manifest()), [])

    def test_rejects_wrong_target_tag(self):
        manifest = valid_manifest()
        manifest["target"]["tag"] = "v0.40.0"
        errors = self.validate(manifest)
        self.assertTrue(any("v0.41.0" in error for error in errors), errors)

    def test_rejects_non_gpu_next_primary_renderer(self):
        manifest = valid_manifest()
        manifest["renderer"]["primary"] = "gpu"
        errors = self.validate(manifest)
        self.assertTrue(any("gpu-next" in error for error in errors), errors)

    def test_rejects_non_gpu_fallback_renderer(self):
        manifest = valid_manifest()
        manifest["renderer"]["fallback"] = "gpu-next"
        errors = self.validate(manifest)
        self.assertTrue(any("fallback" in error and "gpu" in error for error in errors), errors)

    def test_rejects_wrong_media_kit_version(self):
        manifest = valid_manifest()
        manifest["media_kit"]["media_kit_video"] = "1.0.0"
        errors = self.validate(manifest)
        self.assertTrue(any("media_kit_video" in error for error in errors), errors)

    def test_rejects_unknown_platform_status(self):
        manifest = valid_manifest()
        manifest["platforms"]["ios"]["status"] = "maybe"
        errors = self.validate(manifest)
        self.assertTrue(any("status" in error and "ios" in error for error in errors), errors)

    def test_rejects_unapproved_header_hash(self):
        manifest = valid_manifest()
        manifest["target"]["headers"]["client.h"] = "deadbeef"
        errors = self.validate(manifest)
        self.assertTrue(any("client.h" in error for error in errors), errors)


@unittest.skipUnless(VERIFIER_PATH.is_file(), "verifier not implemented yet")
class TargetHeaderVerifierAvailabilityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.verifier = load_verifier()

    def test_target_header_integrity_verifier_exists(self):
        self.assertTrue(
            hasattr(self.verifier, "validate_target_headers"),
            "target header integrity verification has not been implemented yet",
        )


HEADER_VERIFIER_AVAILABLE = False
if VERIFIER_PATH.is_file():
    HEADER_VERIFIER_AVAILABLE = hasattr(load_verifier(), "validate_target_headers")


@unittest.skipUnless(HEADER_VERIFIER_AVAILABLE, "target header verifier not implemented yet")
class TargetHeaderIntegrityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.verifier = load_verifier()

    def test_missing_target_headers_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            errors = self.verifier.validate_target_headers(valid_manifest(), Path(temp_dir))
        self.assertTrue(any("client.h" in error and "missing" in error for error in errors), errors)

    def test_wrong_target_header_content_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            header_dir = root / "third_party" / "mpv" / "v0.41.0"
            header_dir.mkdir(parents=True)
            for name in APPROVED_HEADERS:
                (header_dir / name).write_text("not upstream mpv\n", encoding="utf-8")
            errors = self.verifier.validate_target_headers(valid_manifest(), root)
        self.assertTrue(any("blob hash" in error for error in errors), errors)

    def test_repository_target_headers_match_upstream_blob_hashes(self):
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        self.assertEqual(self.verifier.validate_target_headers(manifest, REPO_ROOT), [])


@unittest.skipUnless(VERIFIER_PATH.is_file(), "verifier not implemented yet")
class RepositoryContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.verifier = load_verifier()

    def test_repository_manifest_exists_and_validates(self):
        self.assertTrue(MANIFEST_PATH.is_file(), "integration.json is missing")
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        self.assertEqual(self.verifier.validate_manifest(manifest, REPO_ROOT), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
