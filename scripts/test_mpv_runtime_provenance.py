#!/usr/bin/env python3
import json
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "third_party" / "mpv" / "integration.json"
DOC_PATH = REPO_ROOT / "docs" / "mpv_runtime_provenance.md"
TARGET = "v0.41.0"
PLATFORMS = ("ios", "macos", "android", "windows")
STRATEGIES = {"upstream-package", "runtime-overlay", "blocked"}


class RuntimeProvenanceContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    def test_every_platform_declares_complete_replacement_boundary(self):
        errors = []
        for platform in PLATFORMS:
            entry = self.manifest["platforms"][platform]
            for field in (
                "runtime_source",
                "runtime_ref",
                "actual_mpv",
                "target_mpv",
                "replacement_strategy",
                "replacement_boundary",
                "provenance_url",
            ):
                value = entry.get(field)
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"{platform}.{field} is missing")
            if entry.get("target_mpv") != TARGET:
                errors.append(f"{platform}.target_mpv must be {TARGET}")
            if entry.get("replacement_strategy") not in STRATEGIES:
                errors.append(
                    f"{platform}.replacement_strategy must be one of {sorted(STRATEGIES)}"
                )
        self.assertEqual(errors, [])

    def test_upgraded_status_requires_actual_target_runtime(self):
        for platform in PLATFORMS:
            entry = self.manifest["platforms"][platform]
            if entry.get("status") == "upgraded":
                self.assertEqual(entry.get("actual_mpv"), TARGET, platform)

    def test_current_boundaries_are_not_falsely_marked_upgraded(self):
        for platform in PLATFORMS:
            entry = self.manifest["platforms"][platform]
            if entry.get("actual_mpv") != TARGET:
                self.assertNotEqual(entry.get("status"), "upgraded", platform)

    def test_provenance_document_exists_and_names_every_platform(self):
        self.assertTrue(DOC_PATH.is_file(), "docs/mpv_runtime_provenance.md is missing")
        text = DOC_PATH.read_text(encoding="utf-8") if DOC_PATH.is_file() else ""
        for platform in PLATFORMS:
            self.assertIn(f"## {platform}", text)
        self.assertIn("gpu-next", text)
        self.assertIn("v0.41.0", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
