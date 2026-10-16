import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

import download_range_experiment as experiment

ROOT = Path(__file__).resolve().parents[1]
DART = shutil.which(os.environ.get("DART", "dart"))


@unittest.skipUnless(DART, "Set DART to a Dart SDK executable for production parity")
class ProductionParityTest(unittest.TestCase):
    def test_executes_production_count_and_inclusive_range_formulas(self):
        source = (ROOT / "lib/core/services/download_parallel.dart").read_text()
        constants = [re.search(r"const int " + name + r" = [^;]+;", source).group()
                     for name in ("kDownloadPartsMin", "kDownloadPartsMax", "kDownloadWorkUnitsMax",
                                  "kDownloadCheckpointTargetBytes", "kDownloadTailBalanceMinUnitBytes")]
        start = source.index("int selectDownloadWorkUnitCount(")
        end = source.index("\nconst String kLogicalDownloadGroup", start)
        transport = (ROOT / "lib/core/services/persistent_parallel_download.dart").read_text()
        bounds = re.search(r"for \(var index = 0; index < count; index\+\+\) \{\n"
                           r"(\s+final from = [^\n]+\n\s+final to = [^\n]+)", transport).group(1)
        mib = experiment.MIB
        sizes = [1, 3, 16, 17, 512 * 1024 - 1, 512 * 1024, 4 * mib - 1,
                 4 * mib, 4 * mib + 1, 16 * mib, 100 * mib, 512 * mib, 752 * mib, 2048 * mib]
        program = "import 'dart:convert';\n" + "\n".join(constants) + source[start:end] + """
void main() {
  final results = [];
  for (final totalBytes in SIZES) {
    for (var width = 1; width <= 16; width++) {
      final count = selectDownloadWorkUnitCount(connections: width, totalBytes: totalBytes);
      final ranges = [];
      for (var index = 0; index < count; index++) {
        BOUNDS
        ranges.add([from, to]);
      }
      results.add([totalBytes, width, ranges]);
    }
  }
  print(jsonEncode(results));
}
""".replace("SIZES", str(sizes)).replace("BOUNDS", bounds)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "parity.dart"
            path.write_text(program)
            result = subprocess.run([DART, str(path)], capture_output=True, text=True, check=True)
        for size, width, ranges in json.loads(result.stdout):
            with self.subTest(size=size, width=width):
                self.assertEqual(experiment.plan_ranges(size, width, 4 * mib),
                                 [tuple(bounds) for bounds in ranges])


class RangePlanTest(unittest.TestCase):
    def test_current_planner_examples(self):
        # Mirrors download_parallel_test.dart, including the 512 KiB floor.
        mib = experiment.MIB
        for size, width, expected in (
            (4 * mib, 4, 8), (16 * mib, 16, 32), (752 * mib, 16, 128),
            (1, 16, 1), (3, 16, 3), (16, 16, 16),
            (4 * mib, 16, 16), (2048 * mib, 1, 128),
        ):
            with self.subTest(size=size, width=width):
                self.assertEqual(len(experiment.plan_ranges(size, width, 4 * mib)), expected)

    def test_proposed_target_preserves_tail_and_cap(self):
        mib = experiment.MIB
        self.assertEqual(len(experiment.plan_ranges(512 * mib, 1, 16 * mib)), 32)
        self.assertEqual(len(experiment.plan_ranges(16 * mib, 8, 16 * mib)), 16)
        self.assertEqual(len(experiment.plan_ranges(2048 * mib, 8, 16 * mib)), 128)

    def test_ranges_cover_every_byte_once_and_are_evenly_divided(self):
        for size in (1, 3, 17, 524287, 524288, 4194305, 788529153):
            for width in (1, 4, 8, 16):
                ranges = experiment.plan_ranges(size, width, 4 * experiment.MIB)
                self.assertEqual(ranges[0][0], 0)
                self.assertEqual(ranges[-1][1], size - 1)
                self.assertTrue(all(a <= b for a, b in ranges))
                self.assertTrue(all(left[1] + 1 == right[0]
                                    for left, right in zip(ranges, ranges[1:])))
                lengths = [b - a + 1 for a, b in ranges]
                self.assertLessEqual(max(lengths) - min(lengths), 1)

    def test_rejects_invalid_inputs(self):
        for size, width, target in ((0, 1, 4), (-1, 1, 4), (10, 0, 4),
                                    (10, 17, 4), (10, 1, 0)):
            with self.subTest(values=(size, width, target)):
                with self.assertRaises(ValueError):
                    experiment.plan_ranges(size, width, target)


class SimulationTest(unittest.TestCase):
    def setUp(self):
        self.origin = experiment.Origin("test", 2, 2, 1)

    def test_single_request_time_includes_setup_and_payload(self):
        result = experiment.simulate([(0, 7)], 1, self.origin)
        self.assertEqual(result["simulated_seconds"], 5)
        self.assertEqual(result["simulated_request_starts"], 1)
        self.assertEqual(result["simulated_wire_bytes"], 8)

    def test_bandwidth_is_shared_instead_of_multiplied_by_width(self):
        ranges = [(0, 3), (4, 7), (8, 11), (12, 15)]
        times = [experiment.simulate(ranges, width, self.origin)["simulated_seconds"]
                 for width in (1, 2, 4)]
        self.assertEqual(times, [12, 10, 9])

    def test_bandwidth_is_reallocated_after_a_short_range_finishes(self):
        result = experiment.simulate([(0, 1), (2, 7)], 2,
                                     experiment.Origin("uneven", 2, 2, 0))
        self.assertEqual(result["simulated_seconds"], 4)
        self.assertEqual(result["simulated_wire_bytes"], 8)

    def test_interruption_retains_or_discards_only_unfinished_bytes(self):
        for retain, seconds, lost in ((True, 7, 0), (False, 8, 2)):
            result = experiment.simulate([(0, 7)], 1, self.origin,
                                         interrupt_at=2, retain_partial=retain)
            self.assertEqual(result["simulated_seconds"], seconds)
            self.assertEqual(result["simulated_request_starts"], 2)
            self.assertEqual(result["simulated_retries"], 1)
            self.assertEqual(result["simulated_inflight_bytes_at_interruption"], 2)
            self.assertEqual(result["simulated_discarded_bytes"], lost)
            self.assertEqual(result["simulated_wire_bytes"], 8 + lost)

    def test_completed_ranges_are_never_redownloaded(self):
        result = experiment.simulate([(0, 3), (4, 7)], 1, self.origin,
                                     interrupt_at=5, retain_partial=False)
        self.assertEqual(result["simulated_completed_ranges_at_interruption"], 1)
        self.assertEqual(result["simulated_discarded_bytes"], 2)
        self.assertEqual(result["simulated_request_starts"], 3)
        self.assertEqual(result["simulated_wire_bytes"], 10)

    def test_completion_at_interruption_time_is_committed_first(self):
        result = experiment.simulate([(0, 7)], 1, self.origin, interrupt_at=5)
        self.assertFalse(result["interruption_applied"])
        self.assertEqual(result["simulated_retries"], 0)
        self.assertEqual(result["simulated_seconds"], 5)

    def test_cut_during_setup_loses_no_bytes(self):
        result = experiment.simulate([(0, 7)], 1, self.origin, interrupt_at=0.5,
                                     retain_partial=False)
        self.assertEqual(result["simulated_discarded_bytes"], 0)
        self.assertEqual(result["simulated_seconds"], 6.5)

    def test_matrix_is_seeded_and_accounts_for_all_bytes(self):
        report = experiment.run_matrix(512 * experiment.MIB, 20261016)
        self.assertEqual(report, experiment.run_matrix(512 * experiment.MIB, 20261016))
        self.assertEqual(len(report["rows"]), 36)
        self.assertNotEqual(report["interrupt_at_seconds"],
                            experiment.run_matrix(512 * experiment.MIB, 7)["interrupt_at_seconds"])
        for row in report["rows"]:
            self.assertLessEqual(row["simulated_peak_active_requests"], row["width"])
            self.assertLessEqual(row["simulated_retries"], row["width"])
            self.assertEqual(row["simulated_request_starts"],
                             row["planned_ranges"] + row["simulated_retries"])
            self.assertAlmostEqual(row["simulated_wire_bytes"],
                                   row["size_bytes"] + row["simulated_discarded_bytes"], places=5)
            if row["recovery"] == "uninterrupted":
                self.assertFalse(row["interruption_applied"])
                self.assertEqual(row["simulated_discarded_bytes"], 0)

    def test_invalid_simulation_inputs_fail_instead_of_looping(self):
        for arguments in (([], 1, self.origin), ([(0, 7)], 0, self.origin),
                          ([(0, 7)], 1, experiment.Origin("bad", 0, 2, 1))):
            with self.assertRaises(ValueError):
                experiment.simulate(*arguments)
        with self.assertRaises(ValueError):
            experiment.simulate([(0, 7)], 1, self.origin, interrupt_at=0)


class CommandLineTest(unittest.TestCase):
    def test_outputs_json_with_requested_size_and_rejects_invalid_size(self):
        command = [sys.executable, str(ROOT / "scripts/download_range_experiment.py"), "--size-mib"]
        result = subprocess.run(command + ["1"], capture_output=True, text=True, check=True)
        report = json.loads(result.stdout)
        self.assertEqual(len(report["rows"]), 36)
        self.assertTrue(all(row["size_bytes"] == experiment.MIB for row in report["rows"]))
        invalid = subprocess.run(command + ["0"], capture_output=True, text=True)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("must be positive", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
