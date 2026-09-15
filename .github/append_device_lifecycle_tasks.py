from pathlib import Path

plan = Path('docs/superpowers/plans/2026-09-15-background-downloader-authority.md')
text = plan.read_text()
marker = '### Task 19: Make iOS continued-processing start state truthful'
if marker in text:
    raise SystemExit('device lifecycle tasks already present')
anchor = '\n## Plan self-review\n'
if anchor not in text:
    raise SystemExit('plan self-review anchor missing')

block = r'''
---

### Task 19: Make iOS continued-processing start state truthful

**Files:**
- Modify: `ios/Runner/DownloadContinuedProcessingManager.swift`
- Test: `test/core/services/ios_continued_processing_start_source_test.dart`

**Interfaces:**
- Contract: a submitted `BGContinuedProcessingTaskRequest` is not considered attached merely because it has an identifier.
- Contract: user-initiated continued processing requests use immediate acceptance/rejection semantics and stale unattached submissions are retried.

- [x] **Step 1: Write RED source contract tests**

Require `.fail` instead of `.queue`, a submission timestamp/grace window, and clearing a request that never reaches `attach(_:)`.

- [x] **Step 2: Run RED before the Swift change**

Expected: FAIL on the old queued-request implementation.

- [x] **Step 3: Implement stale-submission recovery**

Use `request.strategy = .fail`; record `submittedAt` only after successful submission; clear it in `attach`, `finish`, and expiration paths; after the grace interval report the session as lost so Dart retries from live progress.

- [x] **Step 4: Run the source contract and iOS release build**

```bash
flutter test test/core/services/ios_continued_processing_start_source_test.dart
flutter build ios --release --no-codesign
```

Evidence: one-shot run `34998281157` completed RED-before-fix, GREEN-after-fix, source generation, and iOS release/no-codesign build successfully; commit `e2fb824198d940dca695edb249f638755f31fbd0`.

- [ ] **Step 5: Device acceptance**

On a real iOS device start a plugin-parallel episode and verify continued-processing UI/task attaches promptly; background the app and confirm a stale submission is retried rather than remaining falsely active.

---

### Task 20: Keep logical expected size stable across plugin chunk telemetry and pause

**Files:**
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/utils/download_resume.dart` if a pure selector is needed.
- Test: `test/core/services/download_pause_settlement_guard_test.dart`
- Add: `test/core/services/download_expected_size_authority_test.dart`

**Interfaces:**
- Produces: one pure selector for lifecycle checkpoint expected bytes, preferring durable logical/metadata identity over transient plugin/chunk projections.
- Contract: pause must never replace a previously known logical resource size with a smaller chunk-derived/transient total.

- [ ] **Step 1: Write RED regression from device evidence**

Use the observed case `durableExpected=353053603`, transient UI/plugin total `110329255`; the selected lifecycle expected size must remain `353053603`.

- [ ] **Step 2: Verify RED on current pause implementation**

Run the new expected-size test plus `download_pause_settlement_guard_test.dart`.

- [ ] **Step 3: Implement stable size selection**

When persisting pause/resume/cancel lifecycle boundaries, prefer JobStore expected bytes/resource fingerprint, then stable metadata/database size, and use transient projected totals only when no durable size exists. Do not weaken JobStore's mismatched-size rejection.

- [ ] **Step 4: Run focused pause/resource integrity tests and analyzer**

Expected: no `pause.superseded` caused solely by a smaller transient total; resource mismatch protection remains intact.

- [ ] **Step 5: Commit**

```bash
git commit -m "fix(downloads): keep logical size stable across pause"
```

---

### Task 21: Resume plugin-parallel downloads through the same logical parent

**Files:**
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/services/background_downloader_transport.dart` only if the adapter needs a stronger resume outcome.
- Test: `test/core/services/download_plugin_parallel_execution_test.dart`
- Test: `test/core/services/download_pause_settlement_guard_test.dart`

**Interfaces:**
- Contract: a paused plugin `ParallelDownloadTask` resumes through the plugin parent before any legacy import/fresh enqueue path.
- Contract: resume cannot create a second set of chunk identities for the same logical parent while plugin parent/chunk evidence exists.

- [x] **Step 1: Add RED lifecycle regression from the device log**

Assert plugin-parent resume precedes fresh enqueue/legacy import and that existing plugin evidence blocks creating replacement chunks.

- [x] **Step 2: Verify RED on the old implementation**

Focused run `34997190867` failed with the new regressions while five surrounding lifecycle tests passed.

- [x] **Step 3: Route resume to the plugin parent first**

A paused plugin parent attempts `_nativeTransport.resume(task)` before legacy fallback; evidence of the plugin parent/chunks blocks a fresh writer until ownership is settled.

- [x] **Step 4: Run focused tests and analyzer**

Evidence: verified commit `dc9b59c...` passed the focused lifecycle suite and analyzer before commit.

- [ ] **Step 5: Device acceptance**

Pause an active multi-chunk iOS transfer, resume it, and verify the same logical parent continues without a second set of chunk IDs or reset to byte zero.

---

### Task 22: Route cancel and system-cancel by executor ownership, not task shape

**Files:**
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/services/background_downloader_transport.dart` if cancel settlement needs richer evidence.
- Test: `test/core/services/download_cancel_ownership_guard_test.dart`
- Add: `test/core/services/download_plugin_parallel_cancel_routing_test.dart`

**Interfaces:**
- Contract: `ParallelDownloadTask` shape alone never implies legacy `PersistentParallelDownload` ownership.
- Contract: plugin-owned parallel cancel uses `BackgroundDownloaderTransport`; legacy cancel is used only with positive legacy session/manifest ownership evidence.
- Contract: iOS system cancel/expiration is a pause of the current owner, not a destructive migration to the legacy executor.

- [ ] **Step 1: Write RED ownership-routing tests**

Cover plugin parent, legacy manifest parent, unknown/settling ownership, and system-UI cancel.

- [ ] **Step 2: Verify RED**

Expected: current code fails because `parentRecord.task is ParallelDownloadTask` and `_cancelFromSystemUI` choose `_parallel` by task shape.

- [ ] **Step 3: Implement ownership-aware cancel planner**

Use legacy manifest/session evidence first; otherwise use plugin transport for logical plugin parents. Unknown ownership fails closed and keeps the cancel tombstone without deleting bytes.

- [ ] **Step 4: Run cancel/delete/ownership suites and analyzer**

Expected: no surviving writer after settled delete; no plugin parent is sent to legacy cancellation merely because it is parallel.

- [ ] **Step 5: Commit**

```bash
git commit -m "fix(downloads): route parallel cancel by executor ownership"
```

---

### Task 23: Prove kill/relaunch and background survival without duplicate writers

**Files:**
- Modify: `lib/core/services/download_service.dart` only for failures exposed by the matrix.
- Modify: `lib/core/services/background_downloader_transport.dart` only for runtime rehydration failures.
- Add/modify lifecycle recovery tests under `test/core/services/`.
- Update this plan with real-device evidence.

**Interfaces:**
- Contract: relaunch rehydrates/settles the plugin parent before any replacement writer is allowed.
- Contract: user-paused rows remain paused after relaunch; running/interrupted rows reconnect or reschedule without duplicate writers.

- [ ] **Step 1: Extend deterministic recovery regressions**

Cover kill while running, kill while pausing, kill after pause settlement, and relaunch with stale plugin database rows.

- [ ] **Step 2: Run recovery/ownership chaos suites**

Expected: one logical writer maximum and no silent byte-zero restart.

- [ ] **Step 3: Fix any deterministic failures**

Do not open a platform acceptance flag as part of this step.

- [ ] **Step 4: Real-device iOS lifecycle matrix**

Record task/chunk IDs before kill, after relaunch, and after resume. Verify no duplicate writer/chunk generation appears and progress remains monotonic.

- [ ] **Step 5: Gate decision**

Enable iOS plugin parallel only if every device acceptance item passes; otherwise keep the gate false and document the exact remaining blocker.

---

### Task 24: Comprehensive device-derived reliability audit before migration cleanup

**Files:**
- Modify production files only for failures demonstrated by a RED regression or device evidence.
- Add focused tests under `test/core/services/` for every discovered bug.
- Update PR description and this plan with final evidence.

**Interfaces:**
- No new transport abstraction by default. This task is a cross-cutting correctness gate.

- [ ] **Step 1: Audit command/state transitions**

Review start, pause, repeated pause, resume, repeated resume, cancel, delete, app-background/system-expiration, network loss/reconnect, and process relaunch for plugin single, plugin parallel, and legacy fallback.

- [ ] **Step 2: Audit integrity/error transitions**

Review 401/403 signed-URL refresh, incompatible resource fingerprint, 5xx/socket retry ownership, low-disk/no-space, complete-file verification, and stale callbacks after terminal/delete tombstones.

- [ ] **Step 3: Audit queue/session presentation**

Verify episode-level concurrency, one parent slot regardless of chunk count, progress/speed/ETA monotonicity, continued-processing overlay truthfulness, and no stale active UI after pause/cancel.

- [ ] **Step 4: Run focused suites, full Flutter CI, native checks, and supported-platform builds**

Expected: zero failures on the final head; no temporary patch workflow/script remains.

- [ ] **Step 5: Repeat real-device acceptance with a fresh IPA**

At minimum: start, active speed, pause, repeated pause, resume, background, kill/relaunch, 403 refresh if reproducible, cancel/delete, and verify no duplicate writers/orphan chunks.

- [ ] **Step 6: Only then unblock Tasks 14/16/17 cleanup**

Do not remove legacy fallback or transport-state compatibility until the device matrix proves the plugin path is a safe replacement.

'''

text = text.replace(anchor, '\n' + block + anchor, 1)
plan.write_text(text)
