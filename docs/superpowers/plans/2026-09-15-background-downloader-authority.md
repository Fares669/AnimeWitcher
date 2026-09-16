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
- Parent plugin-parallel liveness reconciliation now consults settled package runtime inventory through `BackgroundDownloaderTransport.ownershipFor(parentId)`, matching the logical parent ID and internal chunk `parentTaskId` instead of treating a manually collected child-ID set or stale Transfer projection as proof.
- The temporary package-recovery verification workflow was removed after use; it is not part of the permanent workflow surface.
- Startup recovery waits for the package's native inventory-settlement window before querying/canceling/rescheduling killed tasks, so legacy quarantine cannot race a late native writer.
- Offline holds keep terminal plugin Transfer/database projections terminal and expose `waitingForNetwork` only as AnimeWitcher's logical/UI projection; reconnect resumes through the package Transfer lifecycle.
- Plugin-owned transport tasks use the bounded package retry budget `kDownloadTaskRetries = 3`; URL refresh, resource validation, integrity, offline, and user-intent policy remain application-owned.

### Current automated blocker

The previously recorded automated blocker has been resolved.

- Historical failure: Flutter Checks run **35126994058** on `b957e6c9ba7c1cfabc6462c6c2e099a42c15fa83` had two stale source-contract failures; native logger typecheck, source generation, and analyze were already green.
- The independent lifecycle audit found four real gaps and they were implemented on this branch: settled startup inventory, runtime-inventory ownership, terminal-safe offline projection, and bounded plugin transport retries.
- A stale projection-only parent-ownership source test was then updated in commit `94ac956036647050c148f5eac3aea1bfed4f1e7a` to assert the runtime-inventory contract.
- Current automated head: CI run **35143865770** on `94ac956036647050c148f5eac3aea1bfed4f1e7a` is green: native logger typecheck PASS, source generation PASS, Flutter analyze PASS, and full Flutter tests PASS (`1569` passed, `1` skipped).

**Current state:** Task 35 is implemented and awaiting final CI verification. Task 33 remains a real-device-only acceptance gate; the manual acceptance workflow remains untriggered and no IPA has been built.

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

**Status: DONE; verified on the current production head.**

- [x] Upgrade `pubspec.yaml` from `background_downloader ^9.6.1` to `^9.6.2`.
- [x] Refresh lockfile through dependency resolution.
- [x] Keep package APIs authoritative; do not reproduce the upstream update-stream fix in AnimeWitcher.
- [x] Verify focused download transport coverage on the resulting production head.
- [x] Verify full Flutter tests and analyze on the resulting production head.

Evidence: dependency/design commits `e56a9c43aea5dc19aa1f9ab9c88247e3d0835c55` and `bc8ab4a20fd0b99a4ef894da176c145761fe6a27`; current CI run **35143865770** on `94ac956036647050c148f5eac3aea1bfed4f1e7a` — generation, analyze, native logger typecheck, and full Flutter tests green; `1569` tests passed and `1` skipped.
### Task 27 — Recover zero-byte stale signed-URL plugin state using package lifecycle APIs

**Status: DONE for the automatable scope; real-device evidence remains in Task 33.**

Observed device failure: one child receives HTTP 403 from an expired signed URL; package parallel resume can retain child tasks containing the old URL. When no durable bytes exist, repeatedly resuming that opaque state retries stale children.

Required behavior:

- [x] Do **not** decode/edit package resume JSON or rewrite child URLs manually.
- [x] On a refresh that requires replacement and has zero durable bytes, settle the previous `Transfer` through package APIs.
- [x] Await package terminal settlement (`Transfer.result`) before considering another writer.
- [x] Remove the old transfer through `Transfers.remove(...)` and clear only AnimeWitcher's cached handle bookkeeping.
- [x] Re-check package ownership and start the refreshed task only when ownership is positively `notOwned`.
- [x] Fail closed if cancel/settlement/ownership release cannot be proven.
- [x] Executable coverage is present for zero-byte source refresh routing, package-native cancellation/settlement, Transfer removal, and the no-direct-resume-data-surgery boundary.
- [x] Verify focused + full CI on the resulting head.

Evidence: implementation commits `e56a9c43aea5dc19aa1f9ab9c88247e3d0835c55`, `bc336f190575312c7c1b1178f6c7065d8a07ecd5`, and `b9bdced314a9b0bc0814e310d889b98cc1fbc2df`; current CI run **35143865770** passed `download_plugin_parallel_device_log_regression_test.dart`, `download_plugin_source_refresh_test.dart`, the terminal-safe network-hold guards, and the full suite.
### Task 28 — Eliminate phantom parent `paused` projection while package chunks are alive

**Status: DONE for the automatable scope; real-device evidence remains in Task 33.**

Observed device failure: bytes continued to move in plugin chunks while AnimeWitcher periodically projected the logical parent as `paused`.

- [x] Upgrade to the package version containing the upstream Transfers/tracking update-stream fix (Task 26).
- [x] Stop deciding parent liveness from `liveIds.contains(parentTaskId)` for plugin-parallel work.
- [x] Reconcile plugin-parallel liveness through `BackgroundDownloaderTransport.ownershipFor(parentTaskId)` / package Transfer authority.
- [x] Executable coverage shows runtime-active ownership outranks stale persisted projection and that parent reconciliation asks the transport for targeted ownership.
- [x] Verify no stale fallback code still treats child-ID enumeration as authoritative for plugin-parallel parent ownership.
- [x] Verify focused + full CI.

Evidence: implementation commits `f7c5dafdef91ffa31073b8df8a01c86cf08cf427`, `3513ba4ee8110f6de682c7cf83c0182e4884bcc8`, and `94ac956036647050c148f5eac3aea1bfed4f1e7a`; current CI run **35143865770** passed `download_runtime_ownership_test.dart`, `download_recovery_reconciliation_guard_test.dart`, `download_plugin_parallel_device_log_regression_test.dart`, the startup settlement guard, and the full suite.
### Task 29 — Replace weak source-string regressions with behavioral coverage where feasible

**Status: DONE.**

Some recent regressions were guarded primarily by source-contract string checks. Source guards are retained only for package/architecture boundaries that cannot be cheaply executed; lifecycle decisions have executable policy/ownership coverage.

- [x] Inspect current failing tests in run 35126994058.
- [x] Remove/update stale source anchors that fail despite correct behavior: the package characterization now expects 9.6.2, and the ownership guard now checks the current Transfer projection.
- [x] Behavioral coverage for zero-byte stale source replacement is present through the source-refresh policy and package-native restart contract tests.
- [x] Behavioral coverage for ownership-based parent liveness is present through runtime ownership and targeted Transfer projection tests.
- [x] Preserve source-contract checks only for explicit architecture constraints, including no direct resume-data surgery and plugin/native ownership boundaries.
- [x] Verify the resulting head with analyze and the full Flutter suite.

Evidence: source-contract updates are in `e56a9c43aea5dc19aa1f9ab9c88247e3d0835c55`, `bc336f190575312c7c1b1178f6c7065d8a07ecd5`, and `94ac956036647050c148f5eac3aea1bfed4f1e7a`; current CI run **35143865770** — analyze PASS and `1569` tests passed, `1` skipped.
### Task 30 — Audit remaining custom lifecycle logic against `background_downloader` APIs

**Status: DONE for the current automatable scope; device-gated legacy removal remains intentionally open in Tasks 14, 16, 17, and 33.**

Audit result on head `94ac956036647050c148f5eac3aea1bfed4f1e7a` after the independent lifecycle review:

- [x] Plugin-owned start/reconnect/resume/pause/cancel/restart paths use the package boundary: `Transfers.getOrStart`, `Transfers.rehydrateFromDatabase`, `Transfer.resume/pause/cancel/result`, and `Transfers.remove`.
- [x] Runtime ownership is queried from settled package inventory via `allTasks(allGroups: true)`, matching the exact logical task ID and internal plugin chunk `parentTaskId`; an active Transfer projection without runtime evidence is `unknown`, and persisted JobStore/database status is never proof that a writer exists.
- [x] Direct `FileDownloader` pause/resume/enqueue calls are retained only for legacy multipart children and the verified changed-source Range fallback, where AnimeWitcher still owns the HTTP connection or legacy manifest.
- [x] `PersistentParallelDownload`, `DownloadRangeTransfer`, and the iOS legacy multipart handoff remain fallback/compatibility paths required by the unaccepted device matrix; no safe removal is possible before Task 33 evidence.
- [x] Re-ran the single-writer, relaunch, pause/resume, source-refresh, cancel/delete, queue, ownership, startup-settlement, network-hold, retry, and full Flutter verification in CI run **35143865770**.
- [x] Startup recovery waits five seconds after `FileDownloader.start(...)` before native inventory/cancel/reschedule, matching the package's documented inventory-settlement window.
- [x] Offline network holds preserve terminal plugin rows and publish `waitingForNetwork` only through the logical/UI projection; reconnect routes the final transfer back through `Transfer.resume()`.
- [x] Generic plugin transport failures use the bounded retry budget `kDownloadTaskRetries = 3`; app-owned URL refresh and policy transitions remain separate.
- [x] Documented the dependency contract update from 9.6.1 to 9.6.2 in the design spec.

Ruling: retain the legacy executor and custom Range/iOS paths until the real-device matrix proves the replacement safe; removing them now would leave unsupported or unaccepted platform paths without a verified fallback.

### Task 31 — Keep this plan as the living handoff

**Status: DONE for this session; the maintenance protocol remains binding for future changes.**

- [x] Convert the old static plan into this living status/handoff tracker.
- [x] Add the mandatory update protocol above.
- [x] Record this session's test-contract fixes, dependency-design alignment, CI evidence, lifecycle audit, post-audit hardening, and remaining device gate before handoff.
- [x] Record every implementation/verification commit or discovery from this session through Task 35 in the corresponding task/status sections.

### Task 32 — Restore green automated verification on the current branch

**Status: DONE on head `94ac956036647050c148f5eac3aea1bfed4f1e7a`.**

- [x] Diagnose the Flutter test failure from run **35126994058**: both failures were stale source contracts, not production regressions.
- [x] Fix the root cause without loosening behavioral expectations.
- [x] Run the focused Task 26–29 coverage as part of the full Flutter invocation; the relevant tests passed.
- [x] Run `flutter analyze --no-fatal-warnings --no-fatal-infos`.
- [x] Run the full Flutter test suite: **1569 passed, 1 skipped**.
- [x] Confirm native Swift/logger typecheck remains green.
- [x] Record final run/commit evidence here: CI run **35143865770** on `94ac956036647050c148f5eac3aea1bfed4f1e7a`; post-audit commits include `f7c5dafd`, `b9bdced3`, `93fb1bd9`, and `94ac9560`.

### Task 33 — Real-device acceptance, cleanup, and one final IPA

**Status: BLOCKED / DEVICE ONLY; Task 35 is implemented and awaiting final CI verification before the device gate.**

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

### Task 34 — Post-audit lifecycle hardening

**Status: DONE on head `94ac956036647050c148f5eac3aea1bfed4f1e7a`; verified by CI run 35143865770.**

The independent lifecycle audit of the download authority boundary identified four automatable correctness gaps. Each was implemented with test-first coverage and retained the single-writer fail-closed policy.

- [x] Wait for the package native inventory to settle before startup cancellation/rescheduling.
- [x] Use settled `allTasks(allGroups: true)` plus exact parent/child identity for runtime ownership; projection-only active Transfers remain `unknown`.
- [x] Preserve terminal plugin Transfer/database state during offline holds and expose `waitingForNetwork` only as logical/UI state.
- [x] Set the plugin transport retry budget to the bounded value `kDownloadTaskRetries = 3`.
- [x] Update the stale projection-only ownership source contract without weakening the behavior it protects.
- [x] Verify the focused guards and full Flutter/analysis/native typecheck pipeline.

Evidence: production commits `f7c5dafdef91ffa31073b8df8a01c86cf08cf427`, `b9bdced314a9b0bc0814e310d889b98cc1fbc2df`, and `93fb1bd92e62f8f25b47474b63a775875d33b25b`; test-contract commits `0f776b2175f8dc69a26338a9ca8428a3dc3e4774`, `d876596779f14c3d186bb66ad94abaa0395d675e`, `d010f5a2bddce66f850bafbf44ad7e962d93c831`, `40b9f94d27dc30409d4b21fc868ec1f27ae42e13`, `42f045f51674b8e9d2082ba0391c9742c7cd401e`, `3513ba4ee8110f6de682c7cf83c0182e4884bcc8`, and `94ac956036647050c148f5eac3aea1bfed4f1e7a`; CI run **35143865770** is green with `1569` tests passed and `1` skipped.

### Task 35 — Fail closed when parallel runtime inventory is unavailable

**Status: IMPLEMENTED; verification pending on the resulting head.**

Final review found that `_resumeDownloadTask` could fall through to legacy adoption or a fresh plugin parent when `allTasks(allGroups: true)` threw and no parent Transfer handle was present. That is ambiguous runtime ownership and must not create another writer.

- [x] Add a regression guard requiring an explicit successful runtime-inventory query before legacy adoption or fresh enqueue.
- [x] Preserve the safe package-native path: a known parent Transfer may still attempt `Transfer.resume()`; a failed/unknown parent path returns without creating a replacement writer.
- [ ] Run the focused guard, Flutter analyze, native logger typecheck, and full Flutter suite on the resulting branch head.

Evidence: test commit `b6ffa2f9b81bf7d9e0fa1c718c708f217202f447`; implementation commit `0f32de9f0d6482abb7efb978636cf4121fe4ee8d`; verification is pending.

## Verification ledger

- Historical clean full CI before the latest recovery work: run **35103545336** on `ac82f44959606ed2aa60c6fa08f0d24aaec2542f` — generation/analyze/full Flutter tests/native Swift green.
- Historical focused iOS no-codesign verifier: run **35100980691** — focused ownership regressions and iOS release no-codesign build green at that earlier head. This is **not** evidence for the current head and does not satisfy device acceptance.
- Previous regression run: **35126994058** on `b957e6c9ba7c1cfabc6462c6c2e099a42c15fa83` — native typecheck, generation and analyze green; Flutter tests failed on two stale contracts.
- Intermediate audit-fix run: **35143172041** on `b9bdced314a9b0bc0814e310d889b98cc1fbc2df` — native typecheck and analyze green; Flutter tests exposed one remaining stale projection-only ownership source contract, fixed in `94ac956036647050c148f5eac3aea1bfed4f1e7a`.
- Current verified automated head: run **35143865770** on `94ac956036647050c148f5eac3aea1bfed4f1e7a` — status success; native logger typecheck PASS, source generation PASS, Flutter analyze PASS, full Flutter tests PASS (`1569` passed, `1` skipped).
- The current green run includes the Task 26–32 and Task 34 focused coverage: plugin contract, zero-byte source replacement, runtime parent/child ownership, startup settlement, offline terminal projection, bounded retry, relaunch/single-writer, pause/resume, cancel routing, queue, and source-refresh tests.
- No current run may count as final device acceptance merely because it builds; Task 33 still requires actual iOS device evidence.

## Handoff: exact next actions

1. Automated Tasks 26–32 and Task 34 are complete; Task 35 is implemented and must be marked DONE only after its resulting-head CI verification completes.
2. Task 33 is the only remaining required physical-device gate after Task 35 is green: run the iOS plugin-parallel acceptance workflow and the real-device matrix before changing the production platform gate.
3. Only after real-device acceptance passes may Tasks 14/16/17 cleanup remove the legacy executor, obsolete iOS multipart state, or transport-owned JobStore fields.
4. Do not merge PR #246 or enable a permanent platform acceptance gate without explicit user approval.
