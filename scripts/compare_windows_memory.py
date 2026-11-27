#!/usr/bin/env python3
"""Compare paired samples from measure_windows_memory.ps1 (stdlib only)."""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path

MIB = 1024**2
TICKS_PER_SECOND = 10_000_000
SETTINGS = (
    "osVersion", "logicalProcessors", "artworkQuality", "buildMode",
    "idleSeconds", "settleSeconds", "loopCount", "sampleMillis", "actionTimeoutSeconds",
)
IDENTITY = ("revision", "executableSha256", "aotSha256")


def finite(value: str | float) -> float:
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"non-finite value {value!r}")
    return number


def read_run(directory: Path) -> tuple[dict, dict]:
    run = json.loads((directory / "run.json").read_text(encoding="utf-8-sig"))
    if run.get("schema") != 1 or run.get("hostOs") != "Windows" or run.get("complete") is not True:
        raise ValueError(f"{directory}: expected a complete Windows run")
    phases = ["startup", "home_idle"]
    for index in range(1, run["loopCount"] + 1):
        phases.extend((f"details_{index}_active", f"details_{index}_settle"))
    events = run["events"]
    if [event["phase"] for event in events] != phases:
        raise ValueError(f"{directory}: unexpected phase sequence")
    grouped: dict[str, list] = defaultdict(list)
    total = 0
    last_elapsed = last_ticks = -1
    with (directory / "samples.csv").open(encoding="utf-8-sig", newline="") as source:
        for row in csv.DictReader(source):
            total += 1
            phase = row["phase"]
            elapsed = finite(row["elapsed_seconds"])
            phase_seconds = finite(row["phase_seconds"])
            working_set = int(row["working_set_bytes"])
            private_bytes = int(row["private_bytes"])
            cpu = int(row["cpu_ticks"])
            if (
                int(row["pid"]) != run["processId"] or row["pid"] == "0"
                or elapsed < 0 or elapsed < last_elapsed
                or cpu < 0 or cpu < last_ticks or phase_seconds < 0
                or working_set <= 0 or private_bytes <= 0
            ):
                raise ValueError(f"{directory}: invalid, non-monotonic or mixed-PID sample")
            last_elapsed, last_ticks = elapsed, cpu
            grouped[phase].append((elapsed, phase_seconds, working_set, private_bytes, cpu))
            if phase != phases[len(grouped) - 1] or next(reversed(grouped)) != phase:
                raise ValueError(f"{directory}: out-of-order sample")

    if total != run["sampleCount"] or list(grouped) != phases:
        raise ValueError(f"{directory}: sample count or phases do not match the manifest")
    metrics = {}
    for event in events:
        name = event["phase"]
        samples = grouped[name]
        start, end = finite(event["startSeconds"]), finite(event["endSeconds"])
        max_gap = max((b[0] - a[0] for a, b in zip(samples, samples[1:])), default=0)
        if (
            len(samples) < 2 or samples[-1][0] <= samples[0][0]
            or samples[0][0] < start - 0.000002 or samples[-1][0] > end + 0.000002
        ):
            raise ValueError(f"{directory}: insufficient or out-of-bounds samples in {name}")
        seconds = samples[-1][0] - samples[0][0]
        cpu_seconds = (samples[-1][4] - samples[0][4]) / TICKS_PER_SECOND
        values = {
            "sample_count": len(samples),
            "max_sample_gap_seconds": max_gap,
            "cpu_seconds": cpu_seconds,
            "cpu_percent_of_one_logical_core": 100 * cpu_seconds / seconds,
            "working_set_peak_mib": max(sample[2] for sample in samples) / MIB,
            "private_peak_mib": max(sample[3] for sample in samples) / MIB,
        }
        if name == "startup":
            values["operator_mark_seconds_from_launch"] = end
        if name == "home_idle" or name.endswith("_settle"):
            planned = run["idleSeconds"] if name == "home_idle" else run["settleSeconds"]
            if end - start < planned - 0.001:
                raise ValueError(f"{directory}: too short timed phase {name}")
            # Use the latter half of short settles and cap longer idle windows.
            tail = min(10.0, planned / 2)
            window = [sample for sample in samples if sample[1] >= samples[-1][1] - tail]
            if len(window) < 2:
                raise ValueError(f"{directory}: insufficient settled samples in {name}")
            values["working_set_tail_median_mib"] = statistics.median(row[2] for row in window) / MIB
            values["private_tail_median_mib"] = statistics.median(row[3] for row in window) / MIB
        if name.endswith("_settle"):
            for kind in ("working_set", "private"):
                key = f"{kind}_tail_median_mib"
                values[f"{kind}_tail_change_since_initial_home_mib"] = values[key] - metrics["home_idle"][key]
        metrics[name] = values
    return run, metrics


def check_match(left: dict, right: dict, mode: str) -> None:
    differences = [key for key in SETTINGS if left[key] != right[key]]
    if mode == "artwork":
        if differences != ["artworkQuality"]:
            raise ValueError("artwork comparison must differ only in artwork quality")
    elif differences:
        raise ValueError(f"comparison conditions differ: {', '.join(differences)}")
    differ = [key for key in IDENTITY if left[key] != right[key]]
    if mode in ("aa", "artwork") and differ:
        raise ValueError("control/artwork pairs require identical revision, executable and AOT hashes")
    if mode == "build" and not any(key in differ for key in IDENTITY[1:]):
        raise ValueError("build pairs need distinct executable or AOT hashes, not just different revision labels")
    if (left["variant"], right["variant"]) != (("A", "A") if mode == "aa" else ("A", "B")):
        raise ValueError("each pair must be supplied A then B (A then A for aa controls), regardless of run order")


def compare(pairs: list[tuple[Path, Path]], mode: str) -> dict:
    results = []
    reference_conditions = None
    candidate_identity = None
    distinct_paths: set[Path] = set()
    for ref_dir, cand_dir in pairs:
        resolved = {ref_dir.resolve(), cand_dir.resolve()}
        if len(resolved) != 2 or (distinct_paths & resolved):
            raise ValueError("a capture cannot be reused in a pair or reused as another repetition")
        distinct_paths.update(resolved)
        ref, first = read_run(ref_dir)
        cand, second = read_run(cand_dir)
        check_match(ref, cand, mode)
        condition_keys = SETTINGS + IDENTITY
        ref_conditions = tuple(ref[key] for key in condition_keys)
        cand_conditions = tuple(cand[key] for key in condition_keys)
        if reference_conditions is not None and (
            reference_conditions != ref_conditions or candidate_identity != cand_conditions
        ):
            raise ValueError("all pairs must compare the same reference/candidate and run conditions")
        reference_conditions, candidate_identity = ref_conditions, cand_conditions
        deltas = {
            phase: {metric: second[phase][metric] - value for metric, value in values.items()}
            for phase, values in first.items()
        }
        results.append({"reference": first, "comparison": second, "comparison_minus_reference": deltas})

    median_deltas = {
        phase: {
            metric: statistics.median(pair["comparison_minus_reference"][phase][metric] for pair in results)
            for metric in values
        }
        for phase, values in results[0]["comparison_minus_reference"].items()
    }
    return {
        "mode": mode,
        "pair_count": len(results),
        "reference_conditions": dict(zip(condition_keys, reference_conditions)),
        "comparison_conditions": dict(zip(condition_keys, candidate_identity)),
        "median_comparison_minus_reference": median_deltas,
        "pairs": results,
        "notes": [
            "Single process only: does not include child processes or total GPU allocations.",
            "Working-set peaks are sampled lower bounds. Private bytes are not resident RAM.",
            "Startup includes operator reaction and CPU for active phases depends on action timing.",
            "Not a significance test: run A/A first and compare pair-to-pair variation.",
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("aa", "build", "artwork"), required=True)
    parser.add_argument("--pair", nargs=2, type=Path, metavar=("REFERENCE", "COMPARISON"), required=True, action="append")
    args = parser.parse_args()
    try:
        print(json.dumps(compare(args.pair, args.mode), indent=2, allow_nan=False))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(2, f"cannot compare: {error}\n")


if __name__ == "__main__":
    main()
