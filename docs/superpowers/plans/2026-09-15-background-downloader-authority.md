# Background Downloader Authority — Living Execution Tracker

> **Status:** ACTIVE. This file is the authoritative handoff and progress tracker for PR #246 on branch `refactor/background-downloader-authority`.
>
> **Implementation rule:** use `background_downloader` public APIs for transport lifecycle, ownership, pause/resume/cancel/retry/rehydration whenever the package exposes an equivalent operation. AnimeWitcher should own only logical identity, source refresh, integrity, queue/presentation policy, legacy migration, and documented gaps in the package API.
>
> **Build rule:** do **not** build an acceptance IPA until every automatable item in this tracker is complete and green. The iOS acceptance workflow must remain manual-only until then.

## Goal

Make `background_downloader` the authoritative transport executor for AnimeWitcher downloads while preserving logical episode identity, signed-URL refresh, resource integrity, episode-level queue semantics, relaunch recovery, user pause/delete intent, and the reliability invariants inherited from the download-manager work.

Current package baseline: **`background_downloader ^9.6.2`**.

Design reference: `docs/superpowers/specs/2026-09-15-background-downloader-authority-design.md`.

## Mandatory plan-maintenance protocol

This section is binding for every AI/engineer continuing this branch.

1. **Update this file in the same working session whenever a listed item is completed, its status changes, or its verification evidence changes.** Do not leave completed work unchecked.
2. **Any work discovered or implemented outside the existing tracker must be added here immediately as a new numbered task** before or together with the implementation. No hidden/out-of-plan fixes.
3. A task is `DONE` only after the stated verification ran on the resulting head and the observed evidence matches the expected behavior. A code change by itself is `IMPLEMENTED`, not `DONE`.
4. Record useful evidence beside the task: commit SHA, CI run/job, focused test, device log, or other reproducible proof.
5. Never mark a real-device step complete from compilation, source-contract tests, simulator behavior, or inference. Device-only acceptance requires actual device evidence.
6. If implementation changes the architecture, dependency version, ownership model, fallback policy, acceptance gate, or cleanup order, update the relevant sections of this tracker before moving on.
7. Prefer package-native APIs (`Transfer`, `Transfers`, `FileDownloader` and documented package lifecycle methods) over custom state machines. Custom lifecycle logic requires a documented package-API gap in this file.
8. Preserve **single-writer fail-closed behavior**: unknown/settling ownership must never start a second writer.
9. Existing durable legacy work wins over a new plugin writer until safely settled or explicitly migrated.
10. Do not merge PR #246 or enable a permanent platform acceptance gate without explicit user approval.
11. Do not trigger/build the final acceptance IPA until all automated/code-cleanup work that does not require a physical device is complete and green.

## Authority and safety invariants

- `background_downloader` owns transport execution and transport lifecycle for plugin-owned work.
- AnimeWitcher owns logical task identity, source/signed-URL refresh policy, integrity/resource identity, episode queue semantics, persistence required above the transport layer, and UI projection.
- Exactly one current writer may own a logical file/range.
- Unknown or settling runtime ownership blocks another writer.
- User pause survives relaunch; automatic recovery may not silently override explicit user pause.
- User cancel/delete is terminal for that logical generation and delayed callbacks may not resurrect it.
- A signed-URL refresh must not discard compatible durable bytes merely because the URL string changed.
- Zero-byte stale transport state may be replaced only after the old package-owned transfer is settled and ownership is released.
- Ordinary production/preview builds remain fail-closed for plugin-parallel until the device matrix passes. The compile-time acceptance override is for dedicated acceptance only.
- iOS legacy URLSession multipart and plugin-owned chunks must never both bridge the same logical progress/update authority.

## Current implementation snapshot

### Applied and retained

- A Transfer-backed `BackgroundDownloaderTransport` is the plugin transport boundary.
- Ordinary/plugin-parallel backend selection is centralized and preserves durable legacy continuity.
- Logical parent identity and deterministic plugin task IDs are preserved across retries/relaunch where safe.
- Plugin relaunch recovery, single-writer checks, pause/resume/cancel/delete routing, resource identity, queue semantics, integrity checks, callback authority, and native ownership handoff have regression coverage from the earlier tasks.
- iOS native callback ownership was corrected so plugin-native overlay progress does not also bridge through the legacy Dart multipart path unless it belongs to the legacy bridge group.
- The platform capability gate remains closed for normal builds. A compile-time-only acceptance override exists for a dedicated acceptance artifact.
- `.github/workflows/verify-plugin-parallel-acceptance.yml` is manual-only; normal pushes must not build an IPA.
- `background_downloader` was upgraded from 9.6.1 to **9.6.2** to pick up the upstream fix for update suppression when task tracking/Transfers are active. This matches the observed symptom where native bytes continued while AnimeWitcher projected stale/paused state.
- Zero-byte stale signed-URL recovery is now implemented through package lifecycle primitives rather than direct resume-data surgery: `Transfer.cancel()` → await `Transfer.result` settlement → `Transfers.remove()` → verify `ownershipFor(...) == notOwned` → enqueue/start the refreshed task.
- Parent plugin-parallel liveness reconciliation now consults `BackgroundDownloaderTransport.ownershipFor(parentId)` instead of assuming a live writer must appear under the logical parent ID in a manually collected child-ID set.
- The temporary package-recovery verification workflow was removed after use; it is not part of the permanent workflow surface.

### Current automated blocker

At the last pre-tracker head `b957e6c9ba7c1cfabc6462c6c2e099a42c15fa83`, Flutter Checks run **35126994058** had:

- Native logger typecheck: PASS.
- Source generation: PASS.
- Flutter analyze: PASS.
- Flutter tests: **FAIL**.

**Next action:** inspect the failing test(s), determine whether the failure is a real behavioral regression or a stale/weak source-contract test, fix the root cause, and rerun focused + full CI. No IPA build is allowed during this work.

## Original task status (Tasks 1–25)

These statuses preserve the original task numbering while making the handoff readable. Historical detailed implementation remains represented by the commits/tests in PR #246; any reopened behavior must be tracked below rather than assumed complete.

| Task | Status | Current meaning |
| --- | --- | --- |
| 1 | DONE | Baseline authority boundaries and dependency contract established. |
| 2 | DONE | Stable logical identity and plugin transport identity established. |
| 3 | DONE | Transfer-backed ordinary transport boundary established. |
| 4 | DONE | Deterministic backend selection and legacy continuity established. |
| 5 | DONE | Single-writer/ownership fail-closed policy established. |
| 6 | DONE | Relaunch recovery and persisted intent coverage established. |
| 7 | PARTIAL / DEVICE-BLOCKED | Automated policy/gate coverage exists; final platform acceptance still requires real-device evidence. |
| 8 | DONE | Queue/presentation integration migrated without changing logical episode semantics. |
| 9 | DONE | Pause/resume/cancel routing coverage established. |
| 10 | DONE | Integrity/resource identity policy preserved. |
| 11 | DONE | Failure/retry projection and stale-callback protections added. |
| 12 | DONE | Plugin/native callback authority boundaries added. |
| 13 | DONE | Legacy/plugin ownership handoff and single-writer guards added. |
| 14 | BLOCKED BY DEVICE ACCEPTANCE | Remove `PersistentParallelDownload` from normal new-download execution only after plugin-parallel lifecycle passes the device matrix. |
| 15 | DONE | Plugin-parallel policy/routing scaffolding established. |
| 16 | BLOCKED BY DEVICE ACCEPTANCE | Remove obsolete iOS multipart scheduler state only after no required fallback/device path depends on it. |
| 17 | PARTIAL / BLOCKED | Slim `DownloadJobStore` transport-owned fields after callers/fallbacks are proven removable. |
| 18 | PARTIAL | Final cleanup/build/device signoff remains open. |
| 19 | PARTIAL / DEVICE-BLOCKED | Continued-processing/background attach behavior still needs real iOS device acceptance. |
| 20 | DONE | Automated callback/ownership characterization completed. |
| 21 | PARTIAL / DEVICE-BLOCKED | Pause/resume same logical parent with no duplicate chunk IDs or byte-zero reset still needs real-device proof. |
| 22 | DONE | Automated resource/integrity lifecycle checks completed. |
| 23 | PARTIAL / DEVICE-BLOCKED | Real-device iOS lifecycle matrix and final gate decision remain open. |
| 24 | PARTIAL / DEVICE-BLOCKED | Automated audit completed; fresh acceptance IPA/device run and post-acceptance cleanup remain open. |
| 25 | DONE, FOLLOW-UP ADDED | Signed-URL/resource refresh policy characterized. New zero-byte package-native replacement work is tracked as Tasks 27–29 below. |

## Post-plan follow-up tasks

### Task 26 — Adopt upstream 9.6.2 lifecycle/update fix

**Status: IMPLEMENTED; full-head verification pending because current test suite is red.**

- [x] Upgrade `pubspec.yaml` from `background_downloader ^9.6.1` to `^9.6.2`.
- [x] Refresh lockfile through dependency resolution.
- [x] Keep package APIs authoritative; do not reproduce the upstream update-stream fix in AnimeWitcher.
- [ ] Verify focused download transport tests on the resulting production head.
- [ ] Verify full Flutter tests and analyze on the resulting production head.

### Task 27 — Recover zero-byte stale signed-URL plugin state using package lifecycle APIs

**Status: IMPLEMENTED; verification active.**

Observed device failure: one child receives HTTP 403 from an expired signed URL; package parallel resume can retain child tasks containing the old URL. When no durable bytes exist, repeatedly resuming that opaque state retries stale children.

Required behavior:

- [x] Do **not** decode/edit package resume JSON or rewrite child URLs manually.
- [x] On a refresh that requires replacement and has zero durable bytes, settle the previous `Transfer` through package APIs.
- [x] Await package terminal settlement (`Transfer.result`) before considering another writer.
- [x] Remove the old transfer through `Transfers.remove(...)` and clear only AnimeWitcher's cached handle bookkeeping.
- [x] Re-check package ownership and start the refreshed task only when ownership is positively `notOwned`.
- [x] Fail closed if cancel/settlement/ownership release cannot be proven.
- [ ] Add/strengthen a behavioral regression that proves stale URL → refreshed URL starts a new zero-byte generation without two writers.
- [ ] Verify focused + full CI on the resulting head.

### Task 28 — Eliminate phantom parent `paused` projection while package chunks are alive

**Status: IMPLEMENTED; verification active.**

Observed device failure: bytes continued to move in plugin chunks while AnimeWitcher periodically projected the logical parent as `paused`.

- [x] Upgrade to the package version containing the upstream Transfers/tracking update-stream fix (Task 26).
- [x] Stop deciding parent liveness from `liveIds.contains(parentTaskId)` for plugin-parallel work.
- [x] Reconcile plugin-parallel liveness through `BackgroundDownloaderTransport.ownershipFor(parentTaskId)` / package Transfer authority.
- [ ] Add/strengthen behavioral coverage showing a live/settling package transfer cannot be demoted to `paused` by reconciliation.
- [ ] Verify no stale fallback code still treats child-ID enumeration as authoritative for plugin-parallel parent ownership.
- [ ] Verify focused + full CI.

### Task 29 — Replace weak source-string regressions with behavioral coverage where feasible

**Status: TODO / ACTIVE WITH CURRENT CI INVESTIGATION.**

Some recent regressions were guarded primarily by source-contract string checks. Keep source guards only for architecture boundaries that cannot be cheaply executed; prefer fakes/behavioral tests for lifecycle decisions.

- [ ] Inspect current failing tests in run 35126994058.
- [ ] Remove/update stale source anchors that fail despite correct behavior.
- [ ] Add behavioral coverage for zero-byte stale source replacement.
- [ ] Add behavioral coverage for ownership-based parent liveness.
- [ ] Preserve source-contract checks only for explicit architecture constraints (for example no direct resume-data surgery).

### Task 30 — Audit remaining custom lifecycle logic against `background_downloader` APIs

**Status: TODO.**

For each custom pause/resume/cancel/retry/rehydration/live-task/restart path:

- [ ] Identify the equivalent public package API, if one exists.
- [ ] Replace app-owned lifecycle machinery with the package API where semantics match.
- [ ] For every retained custom path, document the exact package-API gap and why AnimeWitcher must own it.
- [ ] Re-run single-writer, relaunch, pause/resume, source-refresh, cancel/delete, and queue tests after simplification.
- [ ] Do not remove legacy fallback storage/schedulers that are still required by unaccepted device paths.

### Task 31 — Keep this plan as the living handoff

**Status: ONGOING REQUIREMENT.**

- [x] Convert the old static plan into this living status/handoff tracker.
- [x] Add the mandatory update protocol above.
- [ ] Every subsequent implementation/verification commit or discovery must update the corresponding task/status here before the work is considered handed off.

### Task 32 — Restore green automated verification on the current branch

**Status: ACTIVE.**

- [ ] Diagnose Flutter test failure from run **35126994058**.
- [ ] Fix root cause; do not mask real behavior with looser expectations.
- [ ] Run focused tests for Tasks 26–29.
- [ ] Run `flutter analyze --no-fatal-warnings --no-fatal-infos`.
- [ ] Run full Flutter test suite.
- [ ] Confirm native Swift/logger typecheck remains green.
- [ ] Record final run/commit evidence here.

### Task 33 — Real-device acceptance, cleanup, and one final IPA

**Status: BLOCKED until Tasks 26–32 and all other automatable open work are green.**

Do not trigger the IPA before this gate.

Required real iOS acceptance matrix:

- [ ] Start active plugin-parallel download; verify live speed/progress and package ownership.
- [ ] Pause active multi-chunk download; repeated pause is idempotent and no writer survives unexpectedly.
- [ ] Resume the same logical parent; no replacement/duplicate chunk-ID generation and no incorrect byte-zero reset when durable bytes exist.
- [ ] Background / process kill / relaunch; rehydrate without duplicate writers.
- [ ] Exercise expired signed URL / HTTP 401/403 refresh; compatible durable bytes survive, and zero-byte stale state is safely replaced through package APIs.
- [ ] Cancel/delete; no surviving writer or orphan temporary artifacts.
- [ ] Continued-processing/background task attaches to the same logical parent and stale submission retries do not create a second writer.
- [ ] Only after the device matrix passes: decide/record the production platform gate.
- [ ] Only after acceptance: execute Tasks 14/16/17 cleanup and rerun the entire automated suite.
- [ ] Build **one final acceptance IPA** after all non-device work is ready; record artifact/run and device evidence here.

## Verification ledger

- Historical clean full CI before the latest recovery work: run **35103545336** on `ac82f44959606ed2aa60c6fa08f0d24aaec2542f` — generation/analyze/full Flutter tests/native Swift green.
- Historical focused iOS no-codesign verifier: run **35100980691** — focused ownership regressions and iOS release no-codesign build green at that earlier head. This is **not** evidence for the current head and does not satisfy device acceptance.
- Current pre-tracker regression run: **35126994058** on `b957e6c9ba7c1cfabc6462c6c2e099a42c15fa83` — native typecheck, generation and analyze green; Flutter tests red. Must be diagnosed under Task 32.
- No current run is allowed to count as final device acceptance merely because it builds.

## Handoff: exact next actions

1. Inspect the failed Flutter test(s) from run 35126994058 and classify each as production regression vs stale test contract.
2. Fix Task 29/32 failures with focused tests first; update this tracker with the result.
3. Verify Tasks 26–28 behavior on the resulting head, then run full CI.
4. Perform Task 30 package-API audit and remove custom lifecycle code only where the package provides equivalent safe semantics; update this tracker for every change.
5. Complete all automatable cleanup that is not gated on physical-device proof.
6. Only then trigger the manual acceptance IPA and execute Task 33's real-device matrix.
7. If device acceptance passes, perform Tasks 14/16/17 cleanup, rerun full verification, update this tracker, and leave PR #246 ready for explicit user review/merge approval.
