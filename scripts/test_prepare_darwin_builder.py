#!/usr/bin/env python3
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from mpv_runtime.prepare_darwin_builder import (
    OBSOLETE_FFMPEG_DASH_PATCH,
    OBSOLETE_MPV_OBJC_PATCH,
    prepare_patch_compatibility,
)


class PrepareDarwinBuilderPatchTests(unittest.TestCase):
    def make_fixture(self):
        temp = tempfile.TemporaryDirectory()
        root = Path(temp.name)
        builder = root / "builder"
        repo = root / "repo"

        ffmpeg_recipe = builder / "nix/packages/mk-pkg-ffmpeg/default.nix"
        ffmpeg_recipe.parent.mkdir(parents=True)
        ffmpeg_recipe.write_text(
            "before\n" + OBSOLETE_FFMPEG_DASH_PATCH + "after\n",
            encoding="utf-8",
        )

        mpv_recipe = builder / "nix/packages/mk-pkg-mpv/default.nix"
        mpv_recipe.parent.mkdir(parents=True)
        mpv_recipe.write_text(
            "before\n" + OBSOLETE_MPV_OBJC_PATCH + "after\n",
            encoding="utf-8",
        )

        old_patch = builder / "patches/mpv-audiounit-shared-session.patch"
        old_patch.parent.mkdir(parents=True)
        old_patch.write_text(
            "-    [instance setCategory:AVAudioSessionCategoryPlayback error:nil];\n",
            encoding="utf-8",
        )
        new_patch = repo / "third_party/mpv/patches/darwin-audiounit-shared-session-v0.41.patch"
        new_patch.parent.mkdir(parents=True)
        new_patch.write_text(
            "rebased patch with withOptions:options and skip-session-management\n",
            encoding="utf-8",
        )
        return (
            temp,
            builder,
            repo,
            ffmpeg_recipe,
            mpv_recipe,
            old_patch,
            new_patch,
        )

    def test_replaces_only_obsolete_builder_patches(self):
        (
            temp,
            builder,
            repo,
            ffmpeg_recipe,
            mpv_recipe,
            old_patch,
            new_patch,
        ) = self.make_fixture()
        self.addCleanup(temp.cleanup)
        prepare_patch_compatibility(builder, repo)
        self.assertEqual(ffmpeg_recipe.read_text(encoding="utf-8"), "before\nafter\n")
        self.assertEqual(mpv_recipe.read_text(encoding="utf-8"), "before\nafter\n")
        self.assertEqual(
            old_patch.read_text(encoding="utf-8"),
            new_patch.read_text(encoding="utf-8"),
        )

    def test_fails_closed_when_ffmpeg_recipe_drifted(self):
        temp, builder, repo, ffmpeg_recipe, _, _, _ = self.make_fixture()
        self.addCleanup(temp.cleanup)
        ffmpeg_recipe.write_text("no expected patch line\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "FFmpeg DASH patch"):
            prepare_patch_compatibility(builder, repo)

    def test_fails_closed_when_mpv_objc_recipe_drifted(self):
        temp, builder, repo, _, mpv_recipe, _, _ = self.make_fixture()
        self.addCleanup(temp.cleanup)
        mpv_recipe.write_text("no expected patch line\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "Objective-C patch"):
            prepare_patch_compatibility(builder, repo)

    def test_fails_closed_when_audiounit_patch_drifted(self):
        temp, builder, repo, _, _, old_patch, _ = self.make_fixture()
        self.addCleanup(temp.cleanup)
        old_patch.write_text("unexpected patch body\n", encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "AudioUnit patch drifted"):
            prepare_patch_compatibility(builder, repo)


if __name__ == "__main__":
    unittest.main()
