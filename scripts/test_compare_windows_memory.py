#!/usr/bin/env python3
"""Synthetic fixture tests. These do not exercise Windows process counters."""
import csv
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from compare_windows_memory import MIB, compare, read_run


class CompareWindowsMemoryTest(unittest.TestCase):
    def setUp(self):
        self.output = TemporaryDirectory()
        self.addCleanup(self.output.cleanup)
        self.root = Path(self.output.name)

    def capture(self, name, *, candidate=False, ram_offset=0, cpu_step=10_000, metadata=None, corrupt=None):
        out = self.root / name
        out.mkdir()
        run = {
            "schema": 1, "hostOs": "Windows", "osVersion": "Fixture",
            "logicalProcessors": 4, "variant": "B" if candidate else "A",
            "revision": ("b" if candidate else "a") * 40,
            "executableSha256": "e" * 64, "aotSha256": ("d" if candidate else "c") * 64,
            "artworkQuality": "standard", "buildMode": "release", "idleSeconds": 5,
            "settleSeconds": 3, "loopCount": 1, "sampleMillis": 500,
            "actionTimeoutSeconds": 20, "processId": 2048, "complete": True,
            "events": [], "sampleCount": 0,
        }
        phases = (("startup", 1), ("home_idle", 5), ("details_1_active", 2), ("details_1_settle", 3))
        rows = []
        elapsed = 0.0
        for phase, duration in phases:
            parts = duration * 2
            run["events"].append({"phase": phase, "startSeconds": elapsed, "endSeconds": elapsed + duration})
            for part in range(parts + 1):
                rows.append({
                    "elapsed_seconds": elapsed + part * 0.5, "phase": phase, "phase_seconds": part * 0.5,
                    "pid": run["processId"], "working_set_bytes": (100 + ram_offset + part) * MIB,
                    "private_bytes": (250 + 2 * ram_offset + part) * MIB,
                    "cpu_ticks": (len(rows) + 1) * cpu_step, "timestamp_utc": "",
                })
            elapsed += duration + 0.01
        run["sampleCount"] = len(rows)
        run.update(metadata or {})
        if corrupt:
            corrupt(rows)
        (out / "run.json").write_text(json.dumps(run))
        with (out / "samples.csv").open("w", newline="") as file:
            writer = csv.DictWriter(file, rows[0])
            writer.writeheader()
            writer.writerows(rows)
        return out

    def test_working_set_private_and_cpu_kept_separate(self):
        ref = self.capture("a")
        cand = self.capture("b", candidate=True, ram_offset=-25, cpu_step=5000)
        report = compare([(ref, cand)], "build")
        idle = report["median_comparison_minus_reference"]["home_idle"]
        self.assertEqual(idle["working_set_tail_median_mib"], -25)
        self.assertEqual(idle["private_tail_median_mib"], -50)
        self.assertAlmostEqual(idle["cpu_seconds"], -0.005)
        self.assertAlmostEqual(idle["cpu_percent_of_one_logical_core"], -0.1)
        self.assertEqual(report["pairs"][0]["reference"]["startup"]["operator_mark_seconds_from_launch"], 1)

    def test_repeated_build_pairs_and_a_a_controls(self):
        ra, rb = self.capture("a1"), self.capture("b1", candidate=True, ram_offset=-40)
        rc, rd = self.capture("a2"), self.capture("b2", candidate=True, ram_offset=-20)
        report = compare([(ra, rb), (rc, rd)], "build")
        self.assertEqual(report["median_comparison_minus_reference"]["details_1_settle"]["private_peak_mib"], -60)
        report = compare([(ra, rc)], "aa")
        self.assertEqual(report["median_comparison_minus_reference"]["startup"]["working_set_peak_mib"], 0)
        with self.assertRaisesRegex(ValueError, "cannot be reused"):
            compare([(ra, rb), (ra, rd)], "build")

    def test_only_quality_changes_in_artwork_comparison(self):
        a = self.capture("a")
        b = self.capture("b", metadata={"variant": "B", "artworkQuality": "high"})
        self.assertEqual(compare([(a, b)], "artwork")["pair_count"], 1)
        with self.assertRaisesRegex(ValueError, "conditions differ"):
            compare([(a, b)], "build")
        c = self.capture("c", candidate=True, metadata={"artworkQuality": "high"})
        with self.assertRaisesRegex(ValueError, "identical revision"):
            compare([(a, c)], "artwork")

    def test_rejects_incomplete_or_mixed_pid(self):
        with self.assertRaisesRegex(ValueError, "complete Windows"):
            read_run(self.capture("a", metadata={"complete": False}))
        with self.assertRaisesRegex(ValueError, "mixed-PID"):
            read_run(self.capture("b", corrupt=lambda rows: rows[6].update(pid=77)))

    def test_rejects_wrong_order_regressing_cpu_and_nan(self):
        with self.assertRaisesRegex(ValueError, "out-of-order"):
            read_run(self.capture("a", corrupt=lambda rows: rows[-1].update(phase="startup")))
        with self.assertRaisesRegex(ValueError, "non-monotonic"):
            read_run(self.capture("b", corrupt=lambda rows: rows[-1].update(cpu_ticks=1)))
        with self.assertRaisesRegex(ValueError, "non-finite"):
            read_run(self.capture("c", corrupt=lambda rows: rows[-1].update(elapsed_seconds="NaN")))

    def test_rejects_mislabeled_build(self):
        a = self.capture("a")
        b = self.capture("b", metadata={"variant": "B", "revision": "b" * 40})
        with self.assertRaisesRegex(ValueError, "distinct executable or AOT"):
            compare([(a, b)], "build")


if __name__ == "__main__":
    unittest.main()
