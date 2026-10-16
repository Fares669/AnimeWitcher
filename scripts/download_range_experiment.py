"""Offline range-plan experiment, not a native/network performance benchmark."""

import argparse
from collections import deque
from dataclasses import asdict, dataclass
from fractions import Fraction
import json
import random

MIB = 1024 * 1024


def plan_ranges(size, width, target):
    """Mirror selectDownloadWorkUnitCount and inclusive production ranges."""
    if size <= 0 or not 1 <= width <= 16 or target <= 0:
        raise ValueError("Positive size/target and width 1..16 required")
    if size < width:
        count = size
    else:
        desired = min(128, max(width * 2, (size + target - 1) // target))
        size_bound = size // (512 * 1024)
        count = width if size_bound < width else min(size_bound, desired)
    return [(size * index // count, size * (index + 1) // count - 1)
            for index in range(count)]


@dataclass(frozen=True)
class Origin:
    name: str
    aggregate_bytes_per_second: int
    request_bytes_per_second: int
    setup_seconds: float


def simulate(ranges, width, origin, interrupt_at=None, retain_partial=True):
    """Fair-share fluid model; completed ranges survive a single interruption."""
    setup = Fraction(str(origin.setup_seconds))
    interruption = None if interrupt_at is None else Fraction(str(interrupt_at))
    pending = deque(Fraction(end - start + 1) for start, end in ranges)
    if (not pending or min(pending) <= 0 or not 1 <= width <= 16 or setup < 0
            or min(origin.aggregate_bytes_per_second, origin.request_bytes_per_second) <= 0
            or (interruption is not None and interruption <= 0)):
        raise ValueError("Invalid ranges, width, origin, or interruption time")
    active = []
    now = resume_at = Fraction(0)
    starts = retries = completed = peak_active = 0
    discarded = inflight_at_cut = wire_bytes = Fraction(0)
    completed_at_cut = 0
    interrupted = False

    while pending or active:
        while pending and len(active) < width:
            # [size, received bytes, ready time]; setup occupies a request slot.
            active.append([pending.popleft(), Fraction(0), max(now, resume_at) + setup])
            starts += 1
        peak_active = max(peak_active, len(active))
        transferring = [request for request in active if request[2] <= now]
        events = [request[2] for request in active if request[2] > now]
        if transferring:
            rate = min(Fraction(origin.request_bytes_per_second),
                       Fraction(origin.aggregate_bytes_per_second, len(transferring)))
            events.extend(now + (size - received) / rate
                          for size, received, _ in transferring)
        if interruption is not None and not interrupted:
            events.append(interruption)
        next_time = min(events)
        for request in transferring:
            transferred = rate * (next_time - now)
            request[1] += transferred
            wire_bytes += transferred
        now = next_time
        unfinished = [request for request in active if request[1] < request[0]]
        completed += len(active) - len(unfinished)
        active = unfinished
        if now == interruption and (pending or active):
            interrupted = True
            inflight_at_cut = sum((request[1] for request in active), Fraction(0))
            completed_at_cut = completed
            resume_at = now + 1  # Explicit one-second model outage.
            retries += len(active)
            starts += len(active)
            for request in active:
                if not retain_partial:
                    discarded += request[1]
                    request[1] = Fraction(0)
                request[2] = resume_at + setup

    return {
        "simulated_seconds": round(float(now), 6),
        "simulated_request_starts": starts,
        "simulated_retries": retries,
        "simulated_peak_active_requests": peak_active,
        "interruption_applied": interrupted,
        "simulated_completed_ranges_at_interruption": completed_at_cut if interrupted else None,
        "simulated_inflight_bytes_at_interruption": round(float(inflight_at_cut), 6),
        "simulated_discarded_bytes": round(float(discarded), 6),
        "simulated_wire_bytes": round(float(wire_bytes), 6),
    }


def run_matrix(size, seed):
    origins = (
        Origin("reliable", 32 * MIB, 8 * MIB, 0.08),
        Origin("bandwidth_throttled", 4 * MIB, MIB, 0.25),
    )
    # One shared wall-clock cut, independent of the policy and origin.
    interrupt_at = round(4 + 4 * random.Random(seed).random(), 6)
    rows = []
    for origin in origins:
        for target_mib in (4, 16):
            for width in (1, 4, 8):
                ranges = plan_ranges(size, width, target_mib * MIB)
                for recovery in ("uninterrupted", "retain_partial", "lose_partial"):
                    rows.append({
                        "origin": origin.name,
                        "size_bytes": size,
                        "checkpoint_target_mib": target_mib,
                        "width": width,
                        "planned_ranges": len(ranges),
                        "smallest_range_bytes": min(end - start + 1 for start, end in ranges),
                        "largest_range_bytes": max(end - start + 1 for start, end in ranges),
                        "recovery": recovery,
                        **simulate(ranges, width, origin,
                                   interrupt_at=None if recovery == "uninterrupted" else interrupt_at,
                                   retain_partial=recovery != "lose_partial"),
                    })
    return {
        "evidence": "OFFLINE SIMULATION, not a real network or device benchmark",
        "model": "Immediate fixed-width refill; fair bandwidth sharing; per-request setup; "
                 "one interruption; completed ranges always retained. See docs/download-range-experiment.md.",
        "not_measured": ["native callbacks", "OS scheduling", "energy", "disk I/O", "Resume implementation"],
        "seed": seed,
        "interrupt_at_seconds": interrupt_at,
        "interruption_outage_seconds": 1,
        "origins": [asdict(origin) for origin in origins],
        "rows": rows,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size-mib", type=int, default=512)
    parser.add_argument("--seed", type=int, default=20261016)
    args = parser.parse_args()
    if args.size_mib <= 0:
        parser.error("--size-mib must be positive")
    print(json.dumps(run_matrix(args.size_mib * MIB, args.seed), indent=2))


if __name__ == "__main__":
    main()
