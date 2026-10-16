# Immutable-range scheduling experiment

**Offline simulation only. Physical-device performance and reliability remain
unmeasured.** This experiment does not change production defaults, Resume,
existing manifests, or dependencies.

## Run

Python 3.10+ standard library only; no HTTP requests, downloads, or app execution:

```sh
python3 scripts/download_range_experiment.py --size-mib 512 --seed 20261016 > /tmp/range-experiment.json
python3 -m unittest discover -s scripts -p 'test_download_range_experiment.py' -v
```

Repeat with `--size-mib 128`, `752`, and `2048` to see where the tail minimum
and range-count ceiling dominate. Output is self-contained JSON with the
origin assumptions, common interruption time, and 36 result rows. All times,
request starts, retries, and bytes transferred/discarded are model results.
There are no estimated native callback counts.

For a live cross-check of the planner, put `dart` on PATH or set `DART` to its
executable when running the tests. The optional parity test extracts and
executes the unchanged production count function, constants, and inclusive
range-bound formulas in a temporary Dart program. It compares all ranges for
224 cases, covering widths 1–16 and tiny, boundary, and large sizes. Without
Dart, this one test is explicitly skipped; the Python tests still run. This
does not execute the native transport.

## Production behavior represented

Sources: `selectDownloadWorkUnitCount` in
[`download_parallel.dart`](../lib/core/services/download_parallel.dart) and
`PersistentParallelDownload.start` in
[`persistent_parallel_download.dart`](../lib/core/services/persistent_parallel_download.dart).
The baseline was inspected at `c0b1a3f` with background_downloader 9.6.4.

- Current checkpoint target: 4 MiB; candidate: 16 MiB. Both use the current
  128-range cap and 512 KiB minimum for extra tail work.
- For normal-sized files the desired count is the larger of twice the
  connection width and `ceil(total bytes / target)`, capped at 128. The size
  floor can reduce it. Tiny files retain the requested split, bounded by the
  number of bytes.
- Ranges evenly partition the file using `floor(total * index / count)`;
  the checkpoint target is not a promise of exactly that many bytes per range.
- Active widths 1, 4, and 8 are separate from the number of queued ranges.
  Width 1 here is a one-writer immutable-range model, not the app's separate
  whole-file transport path. These are not Auto-setting predictions.

The planner mirror is for positive, known-length files and valid explicit
widths only. It does not model source probing or transport selection. Legacy
512-range manifests remain a production recovery concern and are not replanned.

## Explicit model assumptions

| Synthetic origin | Aggregate payload cap | Per-request payload cap | Setup per request |
| --- | ---: | ---: | ---: |
| reliable | 32 MiB/s | 8 MiB/s | 80 ms |
| bandwidth_throttled | 4 MiB/s | 1 MiB/s | 250 ms |

These are illustrative inputs, not measurements of any provider. Throttling
means a fixed bandwidth cap here; it does not simulate HTTP 429/503 responses.

1. A request occupies one slot during setup, then transfers at the lesser of
   its per-request cap and the aggregate cap divided by currently transferring
   requests. No bandwidth is consumed during setup. Finished slots refill
   immediately. Width is fixed; the app's response-gated ramp, adaptive governor,
   retry backoff, and multi-episode/global budget are not simulated.
2. Exact rational arithmetic advances between setup, completion, and
   interruption events. Only final JSON numbers are rounded to six decimals.
   This is a fluid-byte model, not packet-accurate networking.
3. The seed selects one common interruption time between 4 and 8 seconds for
   every row. The default seed gives **4.533595 seconds**. Runs finishing before
   the cut are explicitly reported as uninterrupted. This is one reproducible
   phase sample, not a statistical estimate of interruption risk.
4. Each origin/target/width combination runs uninterrupted, then with one
   interruption retaining partial bytes, then with one interruption losing
   unfinished partial bytes. Every interrupted request restarts after a
   one-second outage and another setup delay. Completed ranges always survive;
   completions at the cut are committed before interruption.
5. `retain_partial` is an idealized suffix-resume case. `lose_partial` is a
   deliberate stress assumption where no unfinished bytes are recoverable;
   it does not describe normal Resume or claim the app discards partial files.
   Actual recoverability depends on native ownership, saved files, and source
   validation. Neither case exercises those implementations.
6. `simulated_request_starts` counts range attempts including interrupted
   reattempts. `simulated_retries` counts those reattempts, including requests
   interrupted during setup. `simulated_inflight_bytes_at_interruption` is
   unfinished payload already received; `simulated_discarded_bytes` is the
   unrecoverable subset under the chosen assumption. Wire bytes equal file
   size plus discarded bytes. Probe traffic and HTTP overhead are excluded.

No native callbacks, OS scheduling/wakeups, background execution leases, disk
writes/fsync/assembly, verification, CPU, memory, energy, or real-network
throughput are measured. The model cannot justify a production target/width
change or establish iOS background reliability.

## Reproducible example: 512 MiB, seed 20261016

All values below are **simulated**, extracted from the command above. The
current target creates 128 ranges; the candidate creates 32 at all three widths.

| Origin | Target MiB | Width | Uninterrupted seconds | Keep-partial seconds | Lose-partial seconds | Discarded MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| reliable | 4 | 1 | 74.240000 | 75.320000 | 75.713595 | 3.148760 |
| reliable | 4 | 4 | 18.560000 | 19.640000 | 20.033595 | 12.595040 |
| reliable | 4 | 8 | 17.280000 | 18.360000 | 18.493595 | 4.275040 |
| reliable | 16 | 1 | 66.560000 | 67.640000 | 67.933595 | 2.348760 |
| reliable | 16 | 4 | 16.640000 | 17.720000 | 18.013595 | 9.395040 |
| reliable | 16 | 8 | 16.320000 | 17.400000 | 17.773595 | 11.955040 |
| bandwidth_throttled | 4 | 1 | 544.000000 | 545.250000 | 545.283595 | 0.033595 |
| bandwidth_throttled | 4 | 4 | 136.000000 | 137.250000 | 137.283595 | 0.134380 |
| bandwidth_throttled | 4 | 8 | 132.000000 | 133.250000 | 137.533595 | 17.134380 |
| bandwidth_throttled | 16 | 1 | 520.000000 | 521.250000 | 525.533595 | 4.283595 |
| bandwidth_throttled | 16 | 4 | 130.000000 | 131.250000 | 135.533595 | 17.134380 |
| bandwidth_throttled | 16 | 8 | 129.000000 | 130.250000 | 134.533595 | 17.134380 |

Fewer requests reduce this model's assumed setup cost. Its bandwidth cap also
limits the benefit of increasing width. Lost partial bytes depend strongly on
where the cut lands, so one row cannot rank recovery reliability. At 2 GiB,
both target sizes produce 128 ranges: increasing the target does not always
reduce task count. These observations define questions for device testing,
not a recommended default.

## Physical-device protocol before changing defaults

1. Record exact commit/build, background_downloader version, physical device/OS,
   free storage, battery/Low Power Mode, starting thermal state, network path,
   and foreground/locked state. Keep these constant for paired comparisons.
   Keep normal Resume behavior unchanged during the experiment.
2. Use a controlled origin and known SHA-256 fixture at 128, 512, 752, and
   2048 MiB. Log range support, source validators, response byte counts, and
   actual rate limits. Compare fresh test-only 4/16 MiB plans at widths 1/4/8;
   record effective width and actual range count, not just the selected setting.
   Preserve every resumed plan unchanged, including legacy layouts.
3. For each pair, repeat at least five times with recorded randomized order.
   Exercise both an unconstrained and a deliberately rate-limited origin.
   Report per-run observations and median/tail spread; do not hide failures in
   an average. Keep app governor/ramp/retry behavior identical between variants.
4. Measure elapsed wall time, verified output bytes/hash, request attempts,
   actual native and Dart callback counts, durable bytes before/after recovery,
   retransferred bytes, and peak active writers. Separately measure CPU,
   memory, disk I/O, and energy with device tooling; leave unavailable metrics
   unmeasured. Redact URLs, headers, names, and credentials from shared traces.
5. Repeat a documented network interruption, user Pause/Resume, foreground to
   lock, background lease expiration, and relaunch. Separate OS termination
   from user force quit. Record the interruption's wall time and downloaded
   bytes. Check checkpoints and native ownership before calling a stalled
   progress display a failed transfer.
6. Require no lost completed ranges, no duplicate writers, correct final hash,
   honest completion state, and successful recovery across the matrix. A target
   change applies only to newly created test plans; never repartition a partial
   download. Only measured device evidence can support a later production
   change. The physical-device matrix is **PENDING**.
