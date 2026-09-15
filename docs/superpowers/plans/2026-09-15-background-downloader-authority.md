# Background Downloader Authority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `background_downloader 9.6.1` the authoritative transport executor for AnimeWitcher downloads while preserving logical episode identity, signed-URL refresh, resource integrity, episode-level queue semantics, and all reliability invariants merged in PR #231.

**Architecture:** Generalize the existing Transfer-backed transport so ordinary and plugin-parallel downloads share one executor boundary. Keep AnimeWitcher as the logical/policy layer, migrate telemetry and restart recovery to plugin-owned state, introduce `ParallelDownloadTask` behind a deterministic policy gate, then remove custom multipart/range/native scheduling only after equivalent behavior is proven. Legacy custom multipart remains readable during the migration and is never adopted into a new writer without positive ownership/recoverability evidence.

**Tech Stack:** Flutter/Dart 3.13+, `background_downloader ^9.6.1`, Riverpod, Hive, Dio (exceptional verified Range fallback only), iOS Swift/URLSession integration, Android WorkManager/UIDT policy, Flutter test, XCTest/native source guards, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-15-background-downloader-authority-design.md`

## Global Constraints

- Target the currently pinned `background_downloader ^9.6.1` public contract first; no blind dependency upgrade.
- Exactly one current writer may own a logical file/range.
- Unknown or settling runtime ownership blocks another writer.
- User pause survives process restart.
- User delete cannot be resurrected by delayed callbacks.
- Valid partial bytes never silently reset to zero.
- Signed URL refresh must not attach old bytes to an incompatible resource.
- AnimeWitcher logical concurrency counts episodes, not plugin chunks.
- `ParallelDownloadTask` is enabled per platform only after its pause/resume/kill-relaunch matrix passes.
- Existing PR #231 persisted data and completed files remain readable and safe.
- Normal transport retry/stall logic must have exactly one owner.
- Cleanup of legacy multipart/range code happens only after replacement acceptance gates pass.

---

## File structure and responsibility map

### New files

- `lib/core/services/background_downloader_transport.dart` — sole adapter around plugin `Transfer`, including ordinary and `ParallelDownloadTask` execution.
- `lib/core/services/download_transport_policy.dart` — pure task-shape/backend selection; no I/O.
- `lib/core/services/download_transfer_projection.dart` — maps plugin Transfer/task updates to AnimeWitcher presentation telemetry without creating a second byte clock.
- `test/core/services/background_downloader_transport_test.dart` — adapter contract tests.
- `test/core/services/download_transport_policy_test.dart` — backend/task-shape policy tests.
- `test/core/services/download_transfer_projection_test.dart` — progress/speed/ETA projection tests.
- `test/core/services/download_plugin_recovery_contract_test.dart` — startup ordering/reschedule/reconnect contract.
- `test/core/services/download_legacy_migration_policy_test.dart` — coexistence/adoption rules for PR #231 data.

### Existing files that remain policy authorities

- `lib/core/services/download_url_refresh.dart` — provider/source/quality refresh.
- `lib/core/services/download_resource_identity.dart` and resource-fingerprint code in `download_job_store.dart` — compatibility of old bytes with refreshed resource.
- `lib/core/services/download_logical_identity.dart` — stable episode identity.
- `lib/core/utils/download_cleanup.dart` — app-owned file cleanup containment.

### Existing files to shrink progressively

- `lib/core/services/download_transport.dart` — compatibility re-export/type location, then removal of `NativeSingleDownloadTransport` implementation.
- `lib/core/services/download_service.dart` — orchestration only; remove transport internals and duplicate telemetry/recovery decisions.
- `lib/core/services/persistent_parallel_download.dart` — legacy migration path, then delete/retire from normal execution.
- `lib/core/services/download_range_transfer.dart` — isolate to refreshed-source partial recovery, then shrink further if plugin public API proves equivalent.
- `lib/core/services/download_retry_policy.dart` — retain application-level URL-refresh/storage decisions; remove generic retry duplication.
- `ios/Runner/DownloadNativeWaitingQueue.swift` — retain only functionality still required after plugin parallel/native recovery takes ownership.
- `ios/Runner/AppDelegate.swift` / `DownloadCallbackCompatibility.swift` — supported callback integration and minimal compatibility seam only.
- `lib/core/services/download_job_store.dart` — later schema migration from transport-state authority toward logical intent/compatibility state.

---

### Task 1: Lock the migration policy and plugin capability gates

**Files:**
- Create: `lib/core/services/download_transport_policy.dart`
- Create: `test/core/services/download_transport_policy_test.dart`
- Modify: `lib/core/services/download_parallel.dart`

**Interfaces:**
- Produces: `enum DownloadExecutionBackend { pluginSingle, pluginParallel, legacyParallel }`
- Produces: `DownloadExecutionBackend selectDownloadExecutionBackend({required int connections, required bool pluginParallelAccepted, required bool legacySessionExists})`
- Produces: `DownloadTask buildPluginTransportTask({required DownloadTask template, required int connections})`

- [ ] **Step 1: Write RED policy tests**

```dart
void main() {
  test('single connection always uses plugin single transport', () {
    expect(
      selectDownloadExecutionBackend(
        connections: 1,
        pluginParallelAccepted: false,
        legacySessionExists: false,
      ),
      DownloadExecutionBackend.pluginSingle,
    );
  });

  test('new multipart uses plugin only after platform acceptance', () {
    expect(
      selectDownloadExecutionBackend(
        connections: 8,
        pluginParallelAccepted: true,
        legacySessionExists: false,
      ),
      DownloadExecutionBackend.pluginParallel,
    );
  });

  test('existing legacy multipart never changes executor mid-session', () {
    expect(
      selectDownloadExecutionBackend(
        connections: 8,
        pluginParallelAccepted: true,
        legacySessionExists: true,
      ),
      DownloadExecutionBackend.legacyParallel,
    );
  });
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:
```bash
flutter test test/core/services/download_transport_policy_test.dart
```
Expected: FAIL because the new policy/interface does not exist.

- [ ] **Step 3: Implement the minimal pure policy**

```dart
enum DownloadExecutionBackend {
  pluginSingle,
  pluginParallel,
  legacyParallel,
}

DownloadExecutionBackend selectDownloadExecutionBackend({
  required int connections,
  required bool pluginParallelAccepted,
  required bool legacySessionExists,
}) {
  if (legacySessionExists) return DownloadExecutionBackend.legacyParallel;
  if (connections <= 1) return DownloadExecutionBackend.pluginSingle;
  return pluginParallelAccepted
      ? DownloadExecutionBackend.pluginParallel
      : DownloadExecutionBackend.legacyParallel;
}
```

`buildPluginTransportTask` must preserve `taskId`, URL, headers, target path, logical metadata, notification settings/options/hints that are valid for the selected task type, and use `ParallelDownloadTask(chunks: connections)` only when `connections > 1`.

- [ ] **Step 4: Run policy and existing adaptive-part tests**

```bash
flutter test \
  test/core/services/download_transport_policy_test.dart \
  test/features/settings/presentation/download_concurrency_settings_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_transport_policy.dart lib/core/services/download_parallel.dart test/core/services/download_transport_policy_test.dart
git commit -m "refactor(downloads): define plugin transport policy"
```

---

### Task 2: Generalize the Transfer-backed executor

**Files:**
- Create: `lib/core/services/background_downloader_transport.dart`
- Create: `test/core/services/background_downloader_transport_test.dart`
- Modify: `lib/core/services/download_transport.dart`
- Modify: `lib/core/services/download_service.dart`

**Interfaces:**
- Consumes: `DownloadExecutionBackend` from Task 1.
- Produces: `class BackgroundDownloaderTransport implements DownloadTransport`
- Produces: `Future<List<DownloadTask>> rehydrate({String? group})`
- Produces: `Transfer? handleFor(String taskId)`
- Produces: `TaskStatus? statusFor(String taskId)`
- Produces: `bool runtimeStatusCanOwnWriter(String taskId)`

- [ ] **Step 1: Write RED tests that accept both ordinary and parallel tasks**

Test the adapter classification separately from platform I/O:

```dart
test('plugin transport accepts ParallelDownloadTask', () {
  final task = ParallelDownloadTask(
    taskId: 'episode',
    url: 'https://example.test/video.mp4',
    filename: 'episode.mp4',
    group: kLogicalDownloadGroup,
    chunks: 4,
  );
  expect(isBackgroundDownloaderTransportTask(task), isTrue);
});
```

Also assert internal legacy child tasks (`animewitcher_parts`) are not promoted as logical plugin transfers.

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/background_downloader_transport_test.dart
```
Expected: FAIL because the generalized adapter does not exist.

- [ ] **Step 3: Move the existing Transfer implementation into `BackgroundDownloaderTransport`**

The new adapter uses only public plugin APIs:

```dart
Future<bool> start(DownloadTask task) async {
  final existing = handleFor(task.taskId);
  if (existing != null && runtimeTaskStatusCanOwnWriter(existing.status)) {
    _attach(existing);
    return true;
  }
  final transfer = await _downloader.transfers.start(task);
  _attach(transfer);
  return runtimeTaskStatusCanOwnWriter(transfer.status) ||
      transfer.status == TaskStatus.complete;
}
```

Do **not** use a persisted row's presence alone as ownership proof. Rehydrated handles are useful for reconnecting, but `paused/failed/canceled/notFound/complete` cannot own a writer.

Keep `NativeSingleDownloadTransport` temporarily as a deprecated typedef/compatibility alias if needed to avoid one giant call-site diff:

```dart
@Deprecated('Use BackgroundDownloaderTransport')
typedef NativeSingleDownloadTransport = BackgroundDownloaderTransport;
```

- [ ] **Step 4: Run transport tests and analyzer**

```bash
flutter test \
  test/core/services/download_transport_test.dart \
  test/core/services/background_downloader_transport_test.dart
flutter analyze --no-fatal-warnings --no-fatal-infos
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/background_downloader_transport.dart lib/core/services/download_transport.dart lib/core/services/download_service.dart test/core/services/background_downloader_transport_test.dart
git commit -m "refactor(downloads): generalize background downloader transport"
```

---

### Task 3: Make plugin Transfer telemetry authoritative for plugin-owned tasks

**Files:**
- Create: `lib/core/services/download_transfer_projection.dart`
- Create: `test/core/services/download_transfer_projection_test.dart`
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/services/download_telemetry.dart`

**Interfaces:**
- Produces: `DownloadProgressData projectTransferTelemetry({required Task task, required TaskStatus status, required double progress, required double networkSpeedMbPerSecond, required Duration timeRemaining, required int totalSize})`
- Contract: plugin `networkSpeed` is already MB/s; never divide/multiply it through a competing estimator.

- [ ] **Step 1: Write RED telemetry tests**

```dart
test('plugin speed remains authoritative while progress advances', () {
  final projected = projectTransferTelemetry(
    task: DownloadTask(url: 'https://example.test/a', filename: 'a'),
    status: TaskStatus.running,
    progress: 0.25,
    networkSpeedMbPerSecond: 6.5,
    timeRemaining: const Duration(seconds: 20),
    totalSize: 400000000,
  );
  expect(projected.networkSpeed, 6.5);
  expect(projected.timeRemaining, const Duration(seconds: 20));
});
```

Add a stale/status test proving `paused` does not display an invented speed.

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_transfer_projection_test.dart
```
Expected: FAIL.

- [ ] **Step 3: Implement the projection and route plugin-owned transfers through it**

For plugin-authoritative tasks, stop calling `_telemetry.observeProgress` to recompute speed. `DownloadTelemetryEstimator` remains only for legacy custom Range/multipart and compatibility UI where the plugin does not provide a stable metric.

- [ ] **Step 4: Run speed regression suite**

```bash
flutter test \
  test/core/services/download_transfer_projection_test.dart \
  test/core/services/download_ios_restart_telemetry_regression_test.dart \
  test/core/services/persistent_parallel_download_ios_speed_regression_test.dart \
  test/core/services/download_thermal_efficiency_test.dart
```
Expected: PASS; legacy tests continue to use legacy telemetry, plugin path uses plugin speed directly.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_transfer_projection.dart lib/core/services/download_service.dart lib/core/services/download_telemetry.dart test/core/services/download_transfer_projection_test.dart
git commit -m "refactor(downloads): trust plugin transfer telemetry"
```

---

### Task 4: Put plugin startup reconciliation behind a safe recovery gate

**Files:**
- Create: `test/core/services/download_plugin_recovery_contract_test.dart`
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/services/download_service_readiness.dart`

**Interfaces:**
- Produces: `Future<void> _startPluginExecutor()` ordered before custom reconciliation.
- Contract: update listener/callback registration occurs before `FileDownloader.start()`.
- Contract: plugin startup completes before runtime ownership is considered settled.

- [ ] **Step 1: Write RED source/behavior contract tests**

Assert startup order:

```dart
expect(source.indexOf('_fdSubscription ??='), lessThan(source.indexOf('FileDownloader().start(')));
expect(source, contains('doRescheduleKilledTasks: true'));
expect(source.indexOf('FileDownloader().start('), lessThan(source.indexOf('_nativeTransport.rehydrate(')));
```

The exact helper may replace these literal calls; test the helper behavior rather than strings once injectable seams exist.

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_plugin_recovery_contract_test.dart
```
Expected: FAIL because current startup deliberately uses `doRescheduleKilledTasks: false` and subscribes later.

- [ ] **Step 3: Reorder initialization**

Required order:

```text
restore durable user intent
configure plugin
register callbacks/listener
FileDownloader.start(doRescheduleKilledTasks: true, markDownloadedComplete: false)
rehydrate Transfer handles
inventory legacy manifests
logical reconciliation/adoption
publish UI
readiness complete
```

`userPaused` and delete tombstones must be restored **before** plugin reschedule results are projected; if plugin reschedules a task the user intended paused/deleted, AnimeWitcher immediately applies the authoritative logical command before exposing it as active.

- [ ] **Step 4: Run recovery/readiness tests**

```bash
flutter test \
  test/core/services/download_plugin_recovery_contract_test.dart \
  test/core/services/download_initialization_barrier_guard_test.dart \
  test/core/services/download_service_readiness_test.dart \
  test/core/services/download_recovery_reconciliation_guard_test.dart \
  test/core/services/download_zero_restart_invariant_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_service.dart lib/core/services/download_service_readiness.dart test/core/services/download_plugin_recovery_contract_test.dart
git commit -m "refactor(downloads): delegate startup recovery to plugin executor"
```

---

### Task 5: Replace persisted-task liveness guesses with settled Transfer/runtime evidence

**Files:**
- Modify: `lib/core/services/background_downloader_transport.dart`
- Modify: `lib/core/services/download_service.dart`
- Modify: `test/core/services/download_runtime_ownership_test.dart`
- Modify: `test/core/services/download_recovery_reconciliation_guard_test.dart`

**Interfaces:**
- Produces: `Future<DownloadRuntimeOwnership> ownershipFor(String taskId)` on the adapter.
- Consumes: completed plugin startup/reconciliation from Task 4.

- [ ] **Step 1: Write RED ownership tests**

Cover:

```dart
expect(ownershipFromStatus(TaskStatus.paused), DownloadRuntimeOwnership.notOwned);
expect(ownershipFromStatus(TaskStatus.failed), DownloadRuntimeOwnership.notOwned);
expect(ownershipFromStatus(TaskStatus.running), DownloadRuntimeOwnership.owned);
expect(ownershipFromStatus(TaskStatus.enqueued), DownloadRuntimeOwnership.owned);
```

Also cover `runtime query unavailable -> unknown`, not `notOwned`.

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_runtime_ownership_test.dart
```

- [ ] **Step 3: Implement adapter-owned ownership resolution**

Remove ordinary logical ownership decisions based on raw `FileDownloader().allTasks()` membership. A persisted paused/retry row must never reserve a writer slot merely because `allTasks()` returned it.

For iOS gaps where the public plugin API still cannot distinguish a stale `running` projection from a live URLSession task, retain the existing minimal native liveness oracle only as a platform compatibility seam. Do not use it for scheduling plugin parallel children.

- [ ] **Step 4: Run ownership/cancel/pause tests**

```bash
flutter test \
  test/core/services/download_runtime_ownership_test.dart \
  test/core/services/download_cancel_ownership_guard_test.dart \
  test/core/services/download_pause_settlement_guard_test.dart \
  test/core/services/download_recovery_reconciliation_guard_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/background_downloader_transport.dart lib/core/services/download_service.dart test/core/services/download_runtime_ownership_test.dart test/core/services/download_recovery_reconciliation_guard_test.dart
git commit -m "fix(downloads): use settled plugin runtime ownership"
```

---

### Task 6: Add plugin-authoritative parallel execution behind the policy gate

**Files:**
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/services/download_parallel.dart`
- Modify: `lib/core/services/background_downloader_transport.dart`
- Create: `test/core/services/download_plugin_parallel_execution_test.dart`

**Interfaces:**
- Consumes: `selectDownloadExecutionBackend` and `buildPluginTransportTask`.
- Produces: one logical parent `ParallelDownloadTask`; plugin owns internal chunk tasks.

- [ ] **Step 1: Write RED tests for new-download routing**

```dart
test('accepted 8-connection download builds one plugin ParallelDownloadTask', () {
  final task = buildPluginTransportTask(template: template, connections: 8);
  expect(task, isA<ParallelDownloadTask>());
  expect((task as ParallelDownloadTask).chunks, 8);
  expect(task.taskId, template.taskId);
  expect(task.group, kLogicalDownloadGroup);
});
```

Verify no AnimeWitcher `.part.*` child IDs or custom manifest are created for this backend.

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_plugin_parallel_execution_test.dart
```

- [ ] **Step 3: Route only new eligible multipart starts to plugin parallel**

Keep the acceptance flag false by default per platform until Task 10/11 evidence exists. Tests may inject `pluginParallelAccepted: true`.

Do not alter an already-active legacy `PersistentParallelDownload` session.

- [ ] **Step 4: Run focused start/identity tests**

```bash
flutter test \
  test/core/services/download_plugin_parallel_execution_test.dart \
  test/core/services/download_logical_identity_start_test.dart \
  test/core/services/download_job_logical_identity_test.dart \
  test/core/services/download_start_outcome_guard_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_service.dart lib/core/services/download_parallel.dart lib/core/services/background_downloader_transport.dart test/core/services/download_plugin_parallel_execution_test.dart
git commit -m "feat(downloads): add plugin parallel execution path"
```

---

### Task 7: Characterize plugin parallel pause/resume/failure before enabling it

**Files:**
- Create: `test/core/services/download_plugin_parallel_contract_test.dart`
- Modify: `.github/workflows/ci.yml` only if an existing job can host the deterministic characterization without platform-specific flakiness.
- Add native/integration test files only where necessary for iOS/Android acceptance.

**Interfaces:**
- Produces evidence, not a new production abstraction.

- [ ] **Step 1: Add deterministic contract cases**

Required cases:

```text
manual pause -> parent paused -> chunks no longer write
manual resume -> same logical parent continues
cancel -> no chunk writer survives
transient child failure -> documented plugin terminal/retry behavior
kill/relaunch with native survivor -> reconnect without duplicate writer
kill/relaunch with killed worker -> reschedule/recover without permanent running/0 B/s
```

- [ ] **Step 2: Run the Dart-side contract suite**

```bash
flutter test test/core/services/download_plugin_parallel_contract_test.dart
```
Expected: PASS for pure orchestration assertions; platform-specific behavior is not claimed by this test alone.

- [ ] **Step 3: Build/execute platform acceptance**

At minimum:

```bash
flutter build ios --release --no-codesign
flutter build apk --debug
flutter build windows --release
```

And run the repository's available iOS native tests/source guards that exercise background downloader callbacks. Device-only kill/background observations must be recorded in the PR checklist before default enablement.

- [ ] **Step 4: Encode platform capability constants only from evidence**

Example pure API:

```dart
bool pluginParallelAcceptedForPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.iOS => true,   // only after acceptance evidence
  TargetPlatform.android => false,
  _ => false,
};
```

Do not set a platform to `true` merely because it compiles.

- [ ] **Step 5: Commit characterization and accepted capability table**

```bash
git add test/core/services/download_plugin_parallel_contract_test.dart lib/core/services/download_transport_policy.dart
git commit -m "test(downloads): characterize plugin parallel lifecycle"
```

---

### Task 8: Preserve signed-URL refresh without keeping custom Range as normal transport

**Files:**
- Modify: `lib/core/services/download_url_refresh.dart`
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/services/download_range_transfer.dart`
- Create: `test/core/services/download_plugin_source_refresh_test.dart`
- Modify: existing source-refresh/resource-identity tests.

**Interfaces:**
- Produces: `enum RefreshedTransferResumeMode { pluginResume, verifiedRangeFallback, restartRequired, incompatibleResource }`
- Produces: a pure planner selecting mode from resource compatibility, known partial bytes, and plugin resume capability.

- [ ] **Step 1: Write RED refresh planner tests**

```dart
test('changed signed URL with compatible bytes never blindly fresh-starts', () {
  expect(
    planRefreshedTransferResume(
      resourceCompatible: true,
      hasPartialBytes: true,
      pluginCanResumeChangedSource: false,
    ),
    RefreshedTransferResumeMode.verifiedRangeFallback,
  );
});
```

Also test incompatible ETag/size -> `incompatibleResource`, and zero partial bytes -> safe plugin fresh start.

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_plugin_source_refresh_test.dart
```

- [ ] **Step 3: Isolate `DownloadRangeTransfer` to this exceptional seam**

Normal starts, ordinary retry, and ordinary resume must not call `DownloadRangeTransfer`. Only a refreshed URL with valid existing bytes and no safe plugin resume path may enter verified Range recovery.

Retain prefix/If-Range/resource validation for that exceptional case.

- [ ] **Step 4: Run refresh/integrity suite**

```bash
flutter test \
  test/core/services/download_plugin_source_refresh_test.dart \
  test/core/services/download_source_refresh_integrity_test.dart \
  test/core/services/download_source_refresh_service_wiring_test.dart \
  test/core/services/download_resource_identity_test.dart \
  test/core/services/download_durable_only_recovery_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_url_refresh.dart lib/core/services/download_service.dart lib/core/services/download_range_transfer.dart test/core/services/download_plugin_source_refresh_test.dart
git commit -m "refactor(downloads): isolate verified range source refresh"
```

---

### Task 9: Keep episode-level queue semantics while the plugin owns intra-file chunks

**Files:**
- Modify: `lib/core/services/download_concurrency.dart`
- Modify: `lib/core/services/download_service.dart`
- Create: `test/core/services/download_plugin_episode_queue_test.dart`

**Interfaces:**
- Contract: one `ParallelDownloadTask` reserves one logical episode slot, regardless of plugin chunk count.

- [ ] **Step 1: Write RED queue tests**

For `maxConcurrent=2`, enqueue three 8-chunk episodes and assert only two logical parents are handed to transport. Internal plugin chunk count must not influence the third episode's eligibility.

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_plugin_episode_queue_test.dart
```

- [ ] **Step 3: Remove custom child accounting from logical queue decisions**

Keep `Config.holdingQueue` disabled initially if plugin child accounting can deadlock or distort episode semantics. The logical queue may later enable a plugin safety cap only after a dedicated test proves it counts the intended entities.

- [ ] **Step 4: Run queue tests**

```bash
flutter test \
  test/core/services/download_plugin_episode_queue_test.dart \
  test/core/services/download_job_state_queue_authority_test.dart \
  test/features/settings/presentation/download_concurrency_settings_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_concurrency.dart lib/core/services/download_service.dart test/core/services/download_plugin_episode_queue_test.dart
git commit -m "refactor(downloads): preserve logical episode queue over plugin chunks"
```

---

### Task 10: Stop custom iOS multipart promotion for plugin-owned parallel parents

**Files:**
- Modify: `lib/core/services/download_continued_processing_service.dart`
- Modify: `lib/core/services/download_service.dart`
- Modify: `ios/Runner/DownloadNativeWaitingQueue.swift`
- Modify: `ios/Runner/AppDelegate.swift`
- Create/modify: iOS source/native tests for ownership handoff.

**Interfaces:**
- Contract: a plugin-owned `ParallelDownloadTask` is never serialized into AnimeWitcher custom `multipartPlans` / claims.
- Contract: continued-processing session receives parent presentation only.

- [ ] **Step 1: Write RED source/behavior tests**

Assert plugin-authoritative parent snapshots contain no custom multipart claim payload and that normal plugin callbacks still update the session overlay.

- [ ] **Step 2: Run RED**

```bash
flutter test \
  test/core/services/ios_multipart_ownership_handoff_source_test.dart \
  test/core/services/download_native_claim_lifecycle_source_test.dart
```
Expected: at least the new plugin-owned expectations FAIL before production changes.

- [ ] **Step 3: Bypass custom claim/promotion for plugin-owned parallel tasks**

Legacy custom multipart continues to use the old path until removed. Plugin-owned parents remain entirely within `background_downloader` native parallel execution.

- [ ] **Step 4: Verify Swift compilation and native tests**

```bash
flutter build ios --release --no-codesign
```
Run repository native/XCTest coverage for `DownloadNativeWaitingQueue` and callback compatibility. Expected: build/test PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_continued_processing_service.dart lib/core/services/download_service.dart ios/Runner/DownloadNativeWaitingQueue.swift ios/Runner/AppDelegate.swift test/core/services/ios_multipart_ownership_handoff_source_test.dart
git commit -m "refactor(ios): let plugin own parallel transport"
```

---

### Task 11: Establish Android execution policy with UIDT/notification fallback

**Files:**
- Modify: `lib/core/services/download_transport_policy.dart`
- Modify: `lib/core/services/download_transport.dart` or new adapter file.
- Modify: Android manifest/config only if evidence requires it.
- Create: `test/core/services/download_android_transport_policy_test.dart`

**Interfaces:**
- Produces: `AndroidDownloadExecutionPolicy` with ordinary/parallel choice and transfer hints.

- [ ] **Step 1: Write RED Android policy tests**

Cover:

```text
notifications allowed + one connection -> userInitiated/largeFile as appropriate
notifications denied + one connection -> resumable non-UIDT fallback
multiple connections -> plugin parallel only if Android acceptance flag is true
otherwise -> current safe legacy parallel fallback
```

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_android_transport_policy_test.dart
```

- [ ] **Step 3: Implement policy without changing iOS behavior**

No unconditional `TransferHint.userInitiated` when notification requirements are not satisfied.

- [ ] **Step 4: Build Android and run policy suite**

```bash
flutter test test/core/services/download_android_transport_policy_test.dart
flutter build apk --debug
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_transport_policy.dart lib/core/services/background_downloader_transport.dart test/core/services/download_android_transport_policy_test.dart android/app/src/main/AndroidManifest.xml
git commit -m "refactor(android): define plugin download execution policy"
```

---

### Task 12: Formalize coexistence with PR #231 legacy multipart data

**Files:**
- Create: `test/core/services/download_legacy_migration_policy_test.dart`
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/services/persistent_parallel_download.dart`
- Modify: `lib/core/services/download_job_store.dart`

**Interfaces:**
- Produces: `enum LegacyDownloadAdoption { continueLegacy, pluginRehydrate, completed, paused, orphaned }`
- Produces: pure planner using manifest evidence, JobStore intent, plugin record/Transfer state, and final-file evidence.

- [ ] **Step 1: Write RED migration tests**

Required cases:

```text
legacy manifest + incomplete parts -> continueLegacy
plugin task + no legacy manifest -> pluginRehydrate
completed final file -> completed/no writer
userPaused legacy session -> continue paused, no writer
conflicting active ownership -> fail closed/orphaned, never launch both
```

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_legacy_migration_policy_test.dart
```

- [ ] **Step 3: Apply planner during startup inventory**

Do not convert active legacy ranges into plugin chunks. Legacy sessions drain to a stable boundary; only new downloads use the plugin path by default once enabled.

- [ ] **Step 4: Run migration/recovery tests**

```bash
flutter test \
  test/core/services/download_legacy_migration_policy_test.dart \
  test/core/services/download_manifest_startup_inventory_test.dart \
  test/core/services/persistent_parallel_download_manifest_discovery_test.dart \
  test/core/services/download_recovery_inventory_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_service.dart lib/core/services/persistent_parallel_download.dart lib/core/services/download_job_store.dart test/core/services/download_legacy_migration_policy_test.dart
git commit -m "feat(downloads): preserve legacy multipart sessions during migration"
```

---

### Task 13: Enable plugin parallel by accepted platform and run full reliability matrix

**Files:**
- Modify: `lib/core/services/download_transport_policy.dart`
- Modify: `test/core/services/download_manager_chaos_matrix_test.dart`
- Modify/add platform acceptance tests as required.

**Interfaces:**
- Changes acceptance flags from test-only to production defaults only for proven platforms.

- [ ] **Step 1: Expand chaos matrix to run both executor modes where applicable**

Every invariant from the design spec must have at least one automated test. Plugin-path cases include kill/relaunch, pause/resume, 403 refresh, cancel/delete, low disk, and multiple queued episodes.

- [ ] **Step 2: Run full Flutter verification**

```bash
flutter pub get
flutter analyze --no-fatal-warnings --no-fatal-infos
flutter test --dart-define=ANIMEWITCHER_FIREBASE_API_KEY=test-api-key
```
Expected: 0 analyzer errors and 0 test failures.

- [ ] **Step 3: Run platform builds**

Use the repository CI/build matrix for supported platforms. At minimum the branch must compile iOS Swift changes and Android plugin configuration before enabling those platforms.

- [ ] **Step 4: Enable only platforms with completed evidence**

If Android or another platform has an unresolved lifecycle gap, leave that platform on the legacy fallback and keep its plan checkbox open. Do not lower the acceptance bar to make the migration look complete.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_transport_policy.dart test/core/services/download_manager_chaos_matrix_test.dart
git commit -m "feat(downloads): enable accepted plugin parallel backends"
```

---

### Task 14: Remove `PersistentParallelDownload` from normal new-download execution

**Files:**
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/services/persistent_parallel_download.dart`
- Modify: `lib/core/services/download_parallel.dart`
- Remove/retire tests that assert custom scheduling for new downloads; retain legacy migration tests.

**Interfaces:**
- Contract: `PersistentParallelDownload` may be instantiated only for legacy migration inventory until no supported persisted version requires it.

- [ ] **Step 1: Write a RED source/behavior guard**

Assert fresh `startDownload`/equivalent code cannot call `_parallel.start(...)` when plugin parallel is accepted.

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_plugin_parallel_execution_test.dart
```

- [ ] **Step 3: Delete normal-path custom child scheduling**

Remove new-session dependencies on:

```text
custom child Range creation
slow-start batches
pending-start leases
custom connection slots
custom child retry loop
custom aggregate assembly
custom native claim offers
```

Keep only code explicitly required to finish/read legacy sessions.

- [ ] **Step 4: Run full focused multipart + migration suite**

```bash
flutter test test/core/services/persistent_parallel_download_test.dart \
  test/core/services/download_legacy_migration_policy_test.dart \
  test/core/services/download_plugin_parallel_execution_test.dart
```
Expected: PASS, with legacy tests clearly labeled as migration compatibility.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_service.dart lib/core/services/persistent_parallel_download.dart lib/core/services/download_parallel.dart test/core/services
git commit -m "refactor(downloads): retire custom multipart for new transfers"
```

---

### Task 15: Shrink Range/retry code to application-specific exceptional recovery

**Files:**
- Modify: `lib/core/services/download_range_transfer.dart`
- Modify: `lib/core/services/download_retry_policy.dart`
- Modify: `lib/core/services/download_service.dart`
- Modify tests for retry/range behavior.

**Interfaces:**
- Contract: generic socket/5xx/stall retry is plugin-owned for plugin tasks.
- Contract: AnimeWitcher retry planner returns application actions only (`refreshUrl`, `reconcileRange`, `stopNoSpace`, `park/wait`).

- [ ] **Step 1: Write RED tests preventing ordinary plugin tasks from entering Range transport**

```dart
expect(planPluginFailure(statusCode: 503).transportAction,
    PluginTransportAction.leaveToPlugin);
```

403 with refresh capability must remain `refreshUrl`.

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_retry_policy_test.dart
```

- [ ] **Step 3: Remove duplicated generic retry paths**

Keep exact byte/prefix/If-Range logic only in the changed-source exceptional fallback until it can be deleted safely.

- [ ] **Step 4: Run retry/range/resource tests**

```bash
flutter test \
  test/core/services/download_retry_policy_test.dart \
  test/core/services/download_range_checkpoint_backpressure_test.dart \
  test/core/services/download_resource_identity_service_guard_test.dart \
  test/core/services/download_source_refresh_integrity_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_range_transfer.dart lib/core/services/download_retry_policy.dart lib/core/services/download_service.dart test/core/services
git commit -m "refactor(downloads): remove duplicate transport retry logic"
```

---

### Task 16: Remove obsolete iOS multipart scheduler state

**Files:**
- Modify: `ios/Runner/DownloadNativeWaitingQueue.swift`
- Modify: `ios/Runner/DownloadContinuedProcessingManager.swift`
- Modify: `ios/Runner/AppDelegate.swift`
- Modify: `lib/core/services/download_continued_processing_service.dart`
- Modify native/source tests.

**Interfaces:**
- Continued processing accepts logical session summary and plugin parent updates; no multipart claim/promotion protocol remains for new tasks.

- [ ] **Step 1: Identify references that are legacy-only after Task 14**

Delete only symbols with no new plugin-path caller, such as custom `MultipartPlan`/`MultipartClaim` promotion state, after legacy migration policy no longer depends on native scheduling for them.

- [ ] **Step 2: Add/adjust native tests for the reduced bridge**

Required behavior:

```text
start/update/finish continued-processing session
plugin task progress callback -> Dart/session projection
expiration never cancels real download
no custom chunk promotion
```

- [ ] **Step 3: Remove obsolete Swift state and compatibility hooks**

Do not remove diagnostic logging or callback compatibility still required by `background_downloader 9.6.1`.

- [ ] **Step 4: Build iOS**

```bash
flutter build ios --release --no-codesign
```
Expected: PASS. Run selected `RunnerTests`/native static guards as configured by the repository.

- [ ] **Step 5: Commit**

```bash
git add ios/Runner lib/core/services/download_continued_processing_service.dart test/core/services test/native
git commit -m "refactor(ios): remove duplicate multipart scheduler"
```

---

### Task 17: Slim `DownloadJobStore` from transport state to logical intent/compatibility state

**Files:**
- Modify: `lib/core/services/download_job_store.dart`
- Modify: `lib/core/services/download_job_state.dart`
- Modify: `lib/core/services/download_service.dart`
- Add schema migration tests.

**Interfaces:**
- Increment `kDownloadJobSchemaVersion` only with a tested migration.
- Keep logical id, task identity/adoption information, user pause/delete intent, queue intent, resource fingerprint, refresh linkage, and migration metadata.

- [ ] **Step 1: Write migration RED tests from schema v7 rows**

Ensure rows produced by PR #231 decode without losing user pause/delete, logical identity or resource fingerprint.

- [ ] **Step 2: Run RED**

```bash
flutter test test/core/services/download_job_store_test.dart
```

- [ ] **Step 3: Remove transport-owned fields only after all callers are gone**

Do not delete a field because it looks redundant; first prove `git grep`/tests show no correctness dependency. Preserve a compatibility reader for old persisted JSON.

- [ ] **Step 4: Run JobStore/identity/recovery suite**

```bash
flutter test \
  test/core/services/download_job_store_test.dart \
  test/core/services/download_job_state_authority_test.dart \
  test/core/services/download_job_logical_identity_test.dart \
  test/core/services/download_recovery_snapshot_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_job_store.dart lib/core/services/download_job_state.dart lib/core/services/download_service.dart test/core/services
git commit -m "refactor(downloads): reduce job store to logical intent"
```

---

### Task 18: Final cleanup, compatibility GC, and acceptance sign-off

**Files:**
- Delete obsolete production files only if no legacy compatibility path remains.
- Update: `docs/superpowers/specs/2026-09-15-background-downloader-authority-design.md` if final behavior differs from the approved spec.
- Update: this plan checkboxes and final evidence.

**Interfaces:**
- No new interface. This is the removal/verification gate.

- [ ] **Step 1: Prove no normal-path references remain**

Search for:

```bash
git grep -n "PersistentParallelDownload\|kNativeMultipartClaimOfferLease\|downloadConnectionRampBatches\|_rangeTransfers.start"
```

Every surviving reference must be either explicit legacy migration/exceptional refreshed-source recovery or removed.

- [ ] **Step 2: Run full analyzer/test suite fresh**

```bash
flutter pub get
flutter analyze --no-fatal-warnings --no-fatal-infos
flutter test --dart-define=ANIMEWITCHER_FIREBASE_API_KEY=test-api-key
```
Expected: 0 failures.

- [ ] **Step 3: Run supported-platform builds and device acceptance**

Record exact CI run IDs/build artifacts for:

```text
iOS compile + continued-processing/native callback checks
Android APK build + background policy checks
Windows/macOS builds if touched by plugin parallel behavior
```

Device checklist must explicitly include kill/relaunch, pause/resume, active speed, signed-URL refresh, and no duplicate writers.

- [ ] **Step 4: Remove migration-only dead code only after data-compatibility decision**

If old PR #231 multipart manifests must remain readable for at least one release, keep the reader but prevent creation of new manifests. If a migration/GC release has already shipped and telemetry proves no rows remain, delete the reader in a later PR rather than combining risk unnecessarily.

- [ ] **Step 5: Commit final cleanup**

```bash
git add -A
git commit -m "refactor(downloads): complete plugin transport authority migration"
```

- [ ] **Step 6: Final PR gate**

Before marking ready to merge verify:

```text
all plan items supported by evidence are checked
no acceptance flag is enabled without platform evidence
PR is mergeable/conflict-free against current main
full Flutter CI is green on final head
no temporary workflows or diagnostic patch scripts remain
PR description lists remaining legacy fallback, if any, honestly
```

---

## Plan self-review

### Spec coverage

- Plugin transport authority: Tasks 2, 4, 6, 13.
- Plugin telemetry authority: Task 3.
- Runtime ownership safety: Task 5.
- Plugin parallel migration: Tasks 6, 7, 10, 13, 14.
- Signed URL/resource integrity: Task 8 and Task 15.
- Logical episode concurrency: Task 9.
- Android execution differences: Task 11.
- PR #231 persisted compatibility: Task 12 and Task 17.
- iOS native simplification: Task 10 and Task 16.
- JobStore simplification: Task 17.
- Full removal/acceptance gates: Task 18.

### Non-negotiable execution rule

Do not check a task because code was written. Check it only after the task's stated verification has run on the resulting head and the evidence matches the expected result.