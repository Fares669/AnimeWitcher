# Download Manager V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace AnimeWitcher's custom downloader transport/recovery stack with Download Manager V2 using `background_downloader` as the sole transport authority.

**Architecture:** Build V2 beside V1 under `lib/core/services/download_v2/`. V2 stores only logical episode metadata, current generation/task ID, user intent, source descriptor, destination, completion/failure metadata. `background_downloader` owns transfer persistence, pause/resume data, retries, native execution, and package-managed chunks. After automated and physical-device acceptance, production call sites switch to V2 and V1 transport code is removed.

**Tech Stack:** Flutter/Dart 3.13, Riverpod 3, Hive, `background_downloader ^9.6.2`, flutter_test.

**Spec:** `docs/superpowers/specs/2026-09-17-download-manager-v2-design.md`

## Global Constraints

- `background_downloader` is the only V2 transport authority.
- No V2 file imports `persistent_parallel_download.dart` or `download_range_transfer.dart`.
- No V2 persistence contains chunk IDs, range offsets, resume bytes, writer ownership, package retry counters, or package hold state.
- Migration policy A: completed legacy downloads remain; incomplete legacy downloads do not auto-start and restart from byte zero only after user resume/restart.
- Signed URL replacement creates a fresh byte-zero generation.
- Startup matches exact current `taskId`, never URL.
- `active + missing/nonrecoverable package transfer` creates exactly one fresh generation automatically.
- `paused`, `canceled`, and legacy-incomplete records never auto-start.
- Pause intent is persisted before transport pause.
- Cancel/delete fence the old generation before transport cleanup.
- Package `ParallelDownloadTask` children remain opaque to AnimeWitcher.
- V1 is never a fallback for a V2-owned download.
- Device-only acceptance is not considered complete from CI/mocks.

## Locked File Structure

**Create:**
- `lib/core/services/download_v2/download_v2_models.dart`
- `lib/core/services/download_v2/download_v2_identity.dart`
- `lib/core/services/download_v2/logical_download_store_v2.dart`
- `lib/core/services/download_v2/background_downloader_gateway.dart`
- `lib/core/services/download_v2/download_source_resolver_v2.dart`
- `lib/core/services/download_v2/download_integrity_verifier_v2.dart`
- `lib/core/services/download_v2/download_manager_v2.dart`
- `lib/core/services/download_v2/legacy_download_migration_v2.dart`
- `lib/core/services/download_v2/download_v2_diagnostics.dart`
- `lib/core/services/download_v2/download_v2_provider.dart`

**Production cutover files:**
- `lib/main.dart`
- `lib/features/details/presentation/download_launcher.dart` — new-download entry point and source descriptor creation.
- `lib/features/library/presentation/downloads_provider.dart` — download list plus pause/resume/cancel/delete projection/actions.
- `lib/features/details/presentation/downloaded_file_provider.dart` — completed-file lookup.
- `ios/Runner/AppDelegate.swift` and existing native continued-processing bridge files — remove transport authority from V2 path after cutover.

**Tests:** all new V2 tests live under `test/core/services/download_v2/`.

---

### Task 1: Dependency + Identity + Domain Model

**Files:**
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Create: `lib/core/services/download_v2/download_v2_identity.dart`
- Create: `lib/core/services/download_v2/download_v2_models.dart`
- Create: `test/core/services/download_v2/download_v2_identity_test.dart`
- Create: `test/core/services/download_v2/download_v2_models_test.dart`

**Produces:** `DownloadLogicalId`, `DownloadUserIntent`, `DownloadFailureCategory`, `DownloadTransportStatus`, `DownloadTransportSnapshot`, `LogicalDownloadRecordV2`, `logicalDownloadIdFor`, `taskIdForGeneration`, `copyWith`, `toJson`, `fromJson`.

- [ ] Write RED identity/model tests:

```dart
test('task id is deterministic per generation', () {
  final id = logicalDownloadIdFor(
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
  );
  expect(taskIdForGeneration(id, 1), taskIdForGeneration(id, 1));
  expect(taskIdForGeneration(id, 1), isNot(taskIdForGeneration(id, 2)));
});

test('logical record json contains no transport internals', () {
  final json = fixtureRecord().toJson().keys.join('|').toLowerCase();
  for (final forbidden in ['chunk', 'range', 'resumebytes', 'ownership', 'holdreason']) {
    expect(json, isNot(contains(forbidden)));
  }
});
```

- [ ] Run RED:

```bash
flutter test test/core/services/download_v2/download_v2_identity_test.dart test/core/services/download_v2/download_v2_models_test.dart
```

- [ ] Set `background_downloader: ^9.6.2`; implement immutable models and deterministic package-safe task IDs.

Core record fields are exactly: schema version, logical ID, anime ID, episode key, variant key, generation, task ID, intent, destination path, source descriptor, expected bytes if known, completion timestamp, failure category/message, updated timestamp.

- [ ] Run GREEN + analyzer:

```bash
flutter pub get
flutter test test/core/services/download_v2/download_v2_identity_test.dart test/core/services/download_v2/download_v2_models_test.dart
flutter analyze lib/core/services/download_v2
```

- [ ] Commit: `feat(downloads): establish v2 domain model`

---

### Task 2: LogicalDownloadStoreV2

**Files:**
- Create: `lib/core/services/download_v2/logical_download_store_v2.dart`
- Create: `test/core/services/download_v2/logical_download_store_v2_test.dart`

**Produces:** `LogicalDownloadStoreV2`, `HiveLogicalDownloadStoreV2`, `InMemoryLogicalDownloadStoreV2`.

- [ ] Write RED round-trip and mutation tests:

```dart
test('paused intent survives store recreation', () async {
  final backend = <String, Object?>{};
  final first = InMemoryLogicalDownloadStoreV2(backend);
  await first.put(fixtureRecord(intent: DownloadUserIntent.paused));
  final second = InMemoryLogicalDownloadStoreV2(backend);
  expect((await second.all()).single.intent, DownloadUserIntent.paused);
});
```

- [ ] Run RED: `flutter test test/core/services/download_v2/logical_download_store_v2_test.dart`.
- [ ] Implement dedicated Hive box `logical_download_store_v2`; key by `logicalId.value`; persist only `LogicalDownloadRecordV2.toJson()`.
- [ ] Run GREEN.
- [ ] Commit: `feat(downloads): add v2 logical store`.

---

### Task 3: BackgroundDownloaderGateway 9.6.2 Contract

**Files:**
- Create: `lib/core/services/download_v2/background_downloader_gateway.dart`
- Create: `test/core/services/download_v2/background_downloader_gateway_test.dart`
- Create: `test/core/services/download_v2/background_downloader_api_contract_test.dart`

**Produces:** `DownloadTaskSpecV2`, `DownloadTransportHandle`, `BackgroundDownloaderGateway`, `PackageBackgroundDownloaderGateway`.

- [ ] Write RED gateway tests proving one parent spec and no exposed chunk IDs.

```dart
const spec = DownloadTaskSpecV2(
  taskId: 'aw_v2_x_g1',
  url: 'https://example.invalid/video.mp4',
  destinationPath: 'downloads/a.mp4',
  headers: {},
  allowPause: true,
  retries: 2,
  parallelChunks: 5,
);
expect(spec.parallelChunks, 5);
```

- [ ] Run RED.
- [ ] Implement interface:

```dart
abstract interface class BackgroundDownloaderGateway {
  Future<void> initialize();
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec);
  Future<DownloadTransportHandle?> attach(String taskId);
  Future<List<DownloadTransportHandle>> rehydrate();
  Future<void> removeTracking(String taskId);
}

abstract interface class DownloadTransportHandle {
  String get taskId;
  DownloadTransportSnapshot get current;
  Stream<DownloadTransportSnapshot> get snapshots;
  Future<bool> pause();
  Future<bool> resume();
  Future<bool> cancel();
}
```

Concrete initialization calls `FileDownloader().start(autoCleanDatabase: true)`. New work uses `FileDownloader().transfers.start`; persisted work is recovered with `rehydrateFromDatabase`/exact task ID attachment. Single transfers use `DownloadTask`; `parallelChunks > 1` uses package `ParallelDownloadTask` only.

- [ ] Contract-test references `Transfers.start`, `getOrStart`, `rehydrateFromDatabase`, and `Transfer.pause/resume/cancel` so incompatible package changes fail compilation.
- [ ] Run GREEN + analyzer.
- [ ] Commit: `feat(downloads): add background downloader v2 gateway`.

---

### Task 4: Start + Duplicate Coalescing + Generation Fence

**Files:**
- Create: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_manager_v2_start_test.dart`
- Create: `test/core/services/download_v2/download_manager_v2_generation_test.dart`

**Produces:** `DownloadStartRequestV2`, `DownloadManagerV2.start`, `restart`, `snapshotFor`.

- [ ] Write RED tests:

```dart
test('duplicate start creates one writer', () async {
  final f = managerFixture();
  await Future.wait([f.manager.start(f.request), f.manager.start(f.request)]);
  expect(f.gateway.startedSpecs, hasLength(1));
});

test('late old-generation event is ignored', () async {
  final f = managerFixture();
  await f.manager.start(f.request);
  final old = f.gateway.startedSpecs.single.taskId;
  await f.manager.restart(f.request.logicalId);
  f.gateway.emit(old, DownloadTransportStatus.complete);
  expect(f.manager.snapshotFor(f.request.logicalId).taskId, isNot(old));
});
```

- [ ] Run RED.
- [ ] Implement a per-logical-ID command tail/lock; persist generation/task ID before binding callbacks; accept events only when event task ID equals current record task ID.
- [ ] Run GREEN.
- [ ] Commit: `feat(downloads): add v2 start and generation fencing`.

---

### Task 5: Pause / Resume / Cancel / Delete

**Files:**
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_manager_v2_lifecycle_test.dart`

- [ ] Write RED tests for pause ordering, pause fallback, missing-handle resume, cancel late callback, delete idempotence.

```dart
test('pause intent is durable before package pause', () async {
  final f = managerFixture();
  await f.manager.start(f.request);
  f.gateway.onPause = () async {
    expect((await f.store.get(f.request.logicalId))?.intent, DownloadUserIntent.paused);
    return true;
  };
  await f.manager.pause(f.request.logicalId);
});
```

- [ ] Run RED.
- [ ] Implement exact semantics:
  - pause: store paused intent -> package pause; if non-resumable/unsupported, cancel current transport while retaining paused intent.
  - resume: resumable exact current handle -> `resume`; missing/final handle -> fresh generation.
  - cancel/delete: fence old generation first -> cancel -> remove tracking/artifacts; late events ignored.
- [ ] Run GREEN.
- [ ] Commit: `feat(downloads): implement v2 lifecycle commands`.

---

### Task 6: Startup Rehydration / Relaunch Recovery

**Files:**
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_manager_v2_startup_test.dart`

- [ ] Write RED startup matrix:

```dart
expect(startCount(intent: DownloadUserIntent.paused, hasHandle: false), 0);
expect(startCount(intent: DownloadUserIntent.canceled, hasHandle: false), 0);
expect(startCount(intent: DownloadUserIntent.active, hasHandle: true), 0);
expect(startCount(intent: DownloadUserIntent.active, hasHandle: false), 1);
```

Also prove a transfer with the same URL but a different task ID is never adopted.

- [ ] Run RED.
- [ ] Implement `initialize`: gateway initialize -> rehydrate to map keyed by exact `taskId` -> load V2 records -> bind exact current handles -> apply user intent -> create exactly one fresh generation for active missing/nonrecoverable transport.
- [ ] Run GREEN.
- [ ] Commit: `feat(downloads): add deterministic v2 startup recovery`.

---

### Task 7: Fresh Source Resolver + Signed URL Recovery

**Files:**
- Create: `lib/core/services/download_v2/download_source_resolver_v2.dart`
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_manager_v2_source_refresh_test.dart`

**Produces:** `ResolvedDownloadSourceV2`, `DownloadSourceResolverV2`.

- [ ] Write RED test: current-generation 403 produces exactly one resolver call for replacement and one new task ID; old generation is canceled/fenced; new generation starts at byte zero.
- [ ] Run RED.
- [ ] Implement:

```dart
final class ResolvedDownloadSourceV2 {
  const ResolvedDownloadSourceV2({
    required this.url,
    this.headers = const {},
    this.expectedBytes,
  });
  final String url;
  final Map<String, String> headers;
  final int? expectedBytes;
}

abstract interface class DownloadSourceResolverV2 {
  Future<ResolvedDownloadSourceV2> resolve(Map<String, Object?> descriptor);
}
```

At minimum, package HTTP 401/403 is classified as source-expired. Replacement never copies custom resume bytes or ranges.

- [ ] Run GREEN.
- [ ] Commit: `feat(downloads): add v2 signed source recovery`.

---

### Task 8: Final Integrity Gate

**Files:**
- Create: `lib/core/services/download_v2/download_integrity_verifier_v2.dart`
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_manager_v2_completion_test.dart`

- [ ] Write RED test proving package `complete` does not commit logical completion when file is missing, empty, or mismatched trustworthy expected size.
- [ ] Run RED.
- [ ] Implement verifier:

```dart
Future<DownloadIntegrityResult> verify(File file, {int? expectedBytes}) async {
  if (!await file.exists()) return const DownloadIntegrityResult.invalid('missing');
  final bytes = await file.length();
  if (bytes <= 0) return const DownloadIntegrityResult.invalid('empty');
  if (expectedBytes != null && expectedBytes > 0 && bytes != expectedBytes) {
    return DownloadIntegrityResult.invalid('size-mismatch');
  }
  return DownloadIntegrityResult.valid(bytes);
}
```

Only a valid result sets `completedAtMillis`.

- [ ] Run GREEN.
- [ ] Commit: `feat(downloads): gate v2 completion on integrity`.

---

### Task 9: Package Parallelism + Diagnostics

**Files:**
- Modify: `lib/core/services/download_v2/background_downloader_gateway.dart`
- Create: `lib/core/services/download_v2/download_v2_diagnostics.dart`
- Create: `test/core/services/download_v2/download_v2_parallel_test.dart`
- Create: `test/core/services/download_v2/download_v2_diagnostics_test.dart`

- [ ] RED: `parallelChunks: 5` creates one package parent request; AnimeWitcher persists no child IDs.
- [ ] RED: diagnostics never serialize signed URLs/query tokens.
- [ ] Implement package parent mapping and structured events containing logical ID, generation, package task ID, status/hold category, progress, failure category, source-refresh reason, integrity result.
- [ ] Run GREEN.
- [ ] Commit: `feat(downloads): add package parallelism and v2 diagnostics`.

---

### Task 10: Legacy Migration Policy A

**Files:**
- Create: `lib/core/services/download_v2/legacy_download_migration_v2.dart`
- Create: `test/core/services/download_v2/legacy_download_migration_v2_test.dart`

- [ ] RED: completed legacy file remains available and causes zero new transfer starts.
- [ ] RED: incomplete legacy item causes zero network work during migration and one byte-zero V2 generation only after explicit restart/resume.
- [ ] Implement migration using legacy logical/presentation metadata and final-file path only. Do not import chunk IDs, ranges, resume offsets, native ownership, `PersistentParallelDownload`, or `DownloadRangeTransfer` state.
- [ ] Run GREEN.
- [ ] Commit: `feat(downloads): add v2 legacy restart migration`.

---

### Task 11: Riverpod Wiring + Production Cutover Guard

**Files:**
- Create: `lib/core/services/download_v2/download_v2_provider.dart`
- Modify: `lib/main.dart`
- Modify: `lib/features/details/presentation/download_launcher.dart`
- Modify: `lib/features/library/presentation/downloads_provider.dart`
- Modify: `lib/features/details/presentation/downloaded_file_provider.dart`
- Create: `test/core/services/download_v2/download_v2_cutover_guard_test.dart`

- [ ] RED architectural guard scans V2 sources and fails on `PersistentParallelDownload`, `DownloadRangeTransfer`, or imports of their files.
- [ ] RED compatibility tests prove one download action invokes one manager and downloads list no longer reads `FileDownloader().database` directly after cutover.
- [ ] Implement keepAlive provider wiring for concrete store/gateway/source resolver/verifier/diagnostics.
- [ ] In `download_launcher.dart`, keep source selection/metadata confirmation UI but convert the accepted source into `DownloadStartRequestV2` and call V2.
- [ ] In `downloads_provider.dart`, project V2 snapshots and send pause/resume/cancel/delete commands to V2 rather than reconciling plugin DB + JobStore itself.
- [ ] In `downloaded_file_provider.dart`, preserve completed-file lookup across migrated legacy completed items and V2 completed records.
- [ ] Initialize V2 once from `main.dart`/provider lifecycle.
- [ ] Run:

```bash
flutter test test/core/services/download_v2
flutter analyze
flutter test
```

- [ ] Commit: `refactor(downloads): route production downloads through v2`.

---

### Task 12: Native Authority Cleanup + Automated Regression Matrix

**Files:**
- Modify: `ios/Runner/AppDelegate.swift`
- Modify: existing iOS continued-processing/native download bridge files only where they independently enqueue/split/retry/resume/cancel.
- Modify/create tests under `test/core/services/download_v2/`.

- [ ] Add automated regression cases for: start, duplicate start, pause, resume, pause+manager recreation, active+missing recovery, offline hold projection, 403 refresh, cancel/delete stale callback, integrity failure, 5-chunk parent mapping, multiple episodes, completed legacy preserve, incomplete legacy restart.
- [ ] Remove native transport authority from V2 path; native code may remain presentation/telemetry only.
- [ ] Run `flutter analyze` and `flutter test`.
- [ ] Commit: `refactor(downloads): remove native transport authority from v2`.

---

### Task 13: Physical-Device Acceptance Gate

**File:**
- Modify: this plan to record exact evidence.

- [ ] On iOS and Android verify: new complete; pause/resume; pause-kill-relaunch-remains-paused-resume; running termination/relaunch recovery; network loss/recovery; 401/403 fresh byte-zero generation; 5-chunk parallel; multiple episodes; cancel; delete; disk failure; integrity failure; stale old-generation callback; completed legacy playback; incomplete legacy byte-zero restart.
- [ ] Record exact build/run identifiers and observed results.
- [ ] Do not check this task from CI/mocks alone.
- [ ] Commit evidence: `test(downloads): record v2 device acceptance`.

---

### Task 14: Remove V1 Only After Device Gate

**Prerequisite:** Task 13 complete with real-device evidence.

**Files:**
- Delete obsolete V1 executor files including `lib/core/services/persistent_parallel_download.dart`, `lib/core/services/download_range_transfer.dart`, and transport-only ownership/reconciliation code proven unreachable.
- Reduce/remove `lib/core/services/download_service.dart` after its remaining non-V1 responsibilities are moved or shown unused.
- Delete obsolete V1-only tests.

- [ ] Add architecture guard proving production no longer references V1 executor types.
- [ ] Delete only unreachable transport code; retain legacy completed-download metadata reading until no longer required.
- [ ] Run `flutter analyze` and `flutter test`; require exact PR-head CI green.
- [ ] Commit: `refactor(downloads): remove legacy downloader transport`.

---

### Task 15: Final Review / Merge Readiness

- [ ] Compare final diff against every acceptance criterion in the design spec.
- [ ] Re-check duplicate writers, pause ordering, generation fence, relaunch, 403 loop prevention, integrity gate, migration policy A, and absence of V1 fallback.
- [ ] Run `flutter analyze` + `flutter test` from exact head SHA and inspect PR CI for that same SHA.
- [ ] Fix every discovered issue and rerun checks.
- [ ] Mark PR ready only when automated and physical-device gates are actually satisfied. Do not merge unless explicitly requested.
