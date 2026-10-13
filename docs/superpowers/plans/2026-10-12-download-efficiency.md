# Download efficiency implementation plan

> **For agentic workers:** Use superpowers:executing-plans for the sole-writer implementation and an independent whole-diff review.

**Goal:** Reduce redundant download work, keep aggregate metrics stable, and preserve the server's filename.

**Architecture:** Keep the existing coordinator and identity/ownership model. Remove telemetry-only manifest writes, reserve disk probes for silent children, sample routine heartbeats, and prefer fresh parent metrics. Capture filename metadata from existing HTTP probes and pass a safe leaf unchanged to the current destination planner.

**Tech Stack:** Dart, Flutter, Dio, background_downloader; no new dependency.

**Spec:** User-approved scope: simple/lightweight manager; less checkpoint/poll/log work; stable metrics; exact server-provided filename with essential safety/collision handling and fallback when unavailable.

## Global constraints
- Keep synchronous launch-generation, pause, cancellation, and publication checkpoints.
- Preserve exact-size validation, native ownership settlement, logical identity, and exclusive/canonical collision guards.
- No migration or rename of existing files, extra network probes, framework, or dependency.

## Review focus
- One busy child must not hide another child's missing callbacks.
- Repeated identical callbacks must not postpone disk recovery forever.
- Stale aggregate speed must still allow native fallback and expire to zero.
- Header Unicode, spacing, extension, and URL percent escapes must survive exactly once.
- Untrusted filenames must not traverse paths or exceed staging-leaf limits.

## Tasks
1. Coordinator efficiency
   - [x] Add live-progress checkpoint, heartbeat sampling, and per-child polling regressions in persistent_parallel_download_test.dart; observe failures.
   - [x] Remove telemetry-only persistence scheduling, skip recent per-child byte advances for two seconds, and sample heartbeat every five seconds.
   - [ ] Run coordinator tests, including durable disk recovery, pause, crash restore, and final publication.
2. Stable metrics
   - [x] Add parent/native precedence and repeated-zero expiry regressions in download_manager_v2_observation_test.dart; observe failures.
   - [x] Keep fresh positive parent metrics authoritative for three seconds; preserve existing native fallback and avoid refreshing a held-over speed's age.
   - [ ] Run manager and telemetry suites.
3. Server filenames
   - [x] Add probe/planner and actual launcher tests covering header precedence, RFC extended filename, redirect leaf, unsafe names, fallback, and preserved identity; observe failures.
   - [x] Use existing standard-library header parsing and safe leaf validation; pass metadata filename unchanged before existing generated fallback.
   - [ ] Run filename, launcher, identity/collision, and repository test suites.
4. Verification
   - [ ] Independent diff review, targeted analysis, native contracts, and full-suite evidence; commit scoped changes only.

## Decisions
- Diagnostic batching deferred: no measured queue saturation; routine sampling removes work without a new buffering subsystem.
- Existing collision rejection is retained rather than introducing a directory migration.

## Verification evidence
- RED: GitHub Actions run 38300451910. Windows: 55 passed, 3 expected failures (telemetry-only checkpoint sequence 3 to 4; seven fresh-child File constructions instead of zero). Ubuntu focused V2: 492 passed, 8 failures (metrics, single-file rotation, filename behavior, and secondary fixture disposal errors corrected in the test teardown).
- Independent review found no remaining blocker. Current filename helper assertions and Dart syntax parsing pass; full Flutter GREEN remains pending CI because local package downloads are unavailable.
- Keep counter improvements distinct from device CPU or thermal measurements, which this change does not claim.
