# Download Manager V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace AnimeWitcher's custom downloader transport/recovery stack with a small Download Manager V2 that uses `background_downloader` as the sole transport authority while preserving completed legacy downloads and restarting incomplete legacy work cleanly.

**Architecture:** Build V2 beside V1 under `lib/core/services/download_v2/`. V2 persists only application-owned logical metadata and user intent; `background_downloader` owns task execution, pause/resume data, retries, persistence, and package-managed parallel chunks. After automated and physical-device acceptance, route production downloads exclusively through V2 and remove V1 transport/range/multipart ownership machinery.

**Tech Stack:** Flutter/Dart 3.13, Riverpod 3, Hive, `background_downloader ^9.6.2`, flutter_test.

**Spec:** `docs/superpowers/specs/2026-09-17-download-manager-v2-design.md`

## Global Constraints

- `background_downloader` is the only transport authority for V2 downloads.
- V2 must not import `persistent_parallel_download.dart` or `download_range_transfer.dart`.
- V2 must not persist chunk IDs, byte ranges, resume offsets, package retry counters, or writer-ownership state.
- Legacy migration policy A is fixed: completed legacy downloads remain; incomplete legacy downloads restart from byte zero only when the user resumes/restarts them.
- Signed/provider URL replacement starts a fresh generation from byte zero in the first V2 cutover.
- Startup attachment uses the exact current package `taskId`, never URL matching.
- `active + missing/non-recoverable package transfer` starts exactly one fresh generation automatically; `paused`, `canceled`, and legacy-incomplete records never auto-start.
- User pause intent is persisted before transport pause and survives relaunch.
- Cancel/delete advance the generation fence before transport cleanup so late callbacks cannot resurrect work.
- Package-managed `ParallelDownloadTask` may be used; package chunk children remain opaque to AnimeWitcher.
- V1 remains available only until V2 acceptance; it is never a fallback for a V2-owned download.
- No iOS/Android device-only behavior is marked complete from mocks or CI alone.

---

## File Structure

### New V2 production files

- `lib/core/services/download_v2/download_v2_models.dart` — logical record, intent, UI projection, failure categories, package-neutral transport snapshots.
- `lib/core/services/download_v2/download_v2_identity.dart` — stable logical IDs and deterministic generation-specific package task IDs.
- `lib/core/services/download_v2/logical_download_store_v2.dart` — application-owned persistence interface plus Hive backend; no transport-state mirroring.
- `lib/core/services/download_v2/background_downloader_gateway.dart` — mockable package-neutral gateway interface and concrete `background_downloader` adapter.
- `lib/core/services/download_v2/download_source_resolver_v2.dart` — adapter around existing provider/source-resolution behavior returning fresh URL + headers.
- `lib/core/services/download_v2/download_integrity_verifier_v2.dart` — final-file existence/non-empty/expected-size checks.
- `lib/core/services/download_v2/download_manager_v2.dart` — lifecycle coordinator and generation fence.
- `lib/core/services/download_v2/legacy_download_migration_v2.dart` — policy A migration only.
- `lib/core/services/download_v2/download_v2_provider.dart` — Riverpod construction and temporary compatibility surface for UI cutover.
- `lib/core/services/download_v2/download_v2_diagnostics.dart` — structured V2 diagnostics without signed URL/token logging.

### Existing production files modified during cutover

- `pubspec.yaml` and `pubspec.lock` — require `background_downloader ^9.6.2`.
- `lib/main.dart` — initialize package tracking once and initialize V2.
- Existing download UI/provider call sites discovered by code search — switch to V2 compatibility provider only after V2 lifecycle tests are green.
- `ios/Runner/AppDelegate.swift` and existing continued-processing/native bridge files — presentation-only cleanup after V2 cutover; remove any V2-unneeded transport authority.
- V1 downloader files under `lib/core/services/` — delete only after device acceptance proves V2.

### New tests

All new V2 tests live in `test/core/services/download_v2/` and avoid native plugin execution unless explicitly marked contract/integration.

---

### Task 1: Dependency Baseline, Logical Identity, and Minimal V2 Models

**Files:**
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Create: `lib/core/services/download_v2/download_v2_identity.dart`
- Create: `lib/core/services/download_v2/download_v2_models.dart`
- Create: `test/core/services/download_v2/download_v2_identity_test.dart`
- Create: `test/core/services/download_v2/download_v2_models_test.dart`

**Interfaces:**
- Produces: `DownloadLogicalId`, `DownloadUserIntent`, `DownloadFailureCategory`, `DownloadTransportStatus`, `DownloadTransportSnapshot`, `LogicalDownloadRecordV2`, `logicalDownloadIdFor(...)`, `taskIdForGeneration(...)`.

- [ ] **Step 1: Write failing identity tests**

```dart
void main() {
  test('logical id is stable and task id changes only with generation', () {
    final logical = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );
    expect(logical.value, isNotEmpty);
    expect(taskIdForGeneration(logical, 1), taskIdForGeneration(logical, 1));
    expect(taskIdForGeneration(logical, 1), isNot(taskIdForGeneration(logical, 2)));
  });
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run: `flutter test test/core/services/download_v2/download_v2_identity_test.dart test/core/services/download_v2/download_v2_models_test.dart`

Expected: FAIL because V2 files/types do not exist.

- [ ] **Step 3: Upgrade the package floor and implement minimal domain types**

`pubspec.yaml` must contain:

```yaml
background_downloader: ^9.6.2
```

Core model shape:

```dart
enum DownloadUserIntent { active, paused, canceled }
enum DownloadFailureCategory { sourceExpired, transport, filesystem, integrity, unknown }
enum DownloadTransportStatus { queued, running, paused, held, complete, failed, canceled, missing }

final class DownloadLogicalId {
  const DownloadLogicalId(this.value);
  final String value;
}

final class LogicalDownloadRecordV2 {
  const LogicalDownloadRecordV2({
    required this.schemaVersion,
    required this.logicalId,
    required this.generation,
    required this.taskId,
    required this.intent,
    required this.animeId,
    required this.episodeKey,
    required this.variantKey,
    required this.destinationPath,
    required this.sourceDescriptor,
    required this.updatedAtMillis,
    this.completedAtMillis,
    this.failureCategory,
    this.failureMessage,
  });

  final int schemaVersion;
  final DownloadLogicalId logicalId;
  final int generation;
  final String taskId;
  final DownloadUserIntent intent;
  final String animeId;
  final String episodeKey;
  final String variantKey;
  final String destinationPath;
  final Map<String, Object?> sourceDescriptor;
  final int updatedAtMillis;
  final int? completedAtMillis;
  final DownloadFailureCategory? failureCategory;
  final String? failureMessage;
}
```

Task IDs must be deterministic, package-safe, and must not contain a signed URL.

- [ ] **Step 4: Run focused tests and analyzer**

Run:

```bash
flutter pub get
flutter test test/core/services/download_v2/download_v2_identity_test.dart test/core/services/download_v2/download_v2_models_test.dart
flutter analyze lib/core/services/download_v2
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/core/services/download_v2 test/core/services/download_v2
git commit -m "feat(downloads): establish v2 domain model"
```

---

### Task 2: LogicalDownloadStoreV2 — Application Metadata Only

**Files:**
- Create: `lib/core/services/download_v2/logical_download_store_v2.dart`
- Create: `test/core/services/download_v2/logical_download_store_v2_test.dart`

**Interfaces:**
- Consumes: `LogicalDownloadRecordV2` from Task 1.
- Produces: `LogicalDownloadStoreV2.get`, `.put`, `.remove`, `.all`, `.mutate`; `HiveLogicalDownloadStoreV2`; `InMemoryLogicalDownloadStoreV2` for tests.

- [ ] **Step 1: Write failing persistence/serialization tests**

```dart
test('store round-trips logical metadata without transport internals', () async {
  final store = InMemoryLogicalDownloadStoreV2();
  final record = fixtureRecord(intent: DownloadUserIntent.paused);
  await store.put(record);
  final loaded = await store.get(record.logicalId);
  expect(loaded?.intent, DownloadUserIntent.paused);
  expect(loaded?.generation, record.generation);
  expect(loaded?.taskId, record.taskId);
});
```

Also assert serialized JSON has no keys matching `chunk`, `range`, `resumeBytes`, `ownership`, `retryRemaining`, or `holdReason`.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/services/download_v2/logical_download_store_v2_test.dart`

Expected: FAIL because the store is absent.

- [ ] **Step 3: Implement a small store with a dedicated Hive box**

```dart
abstract interface class LogicalDownloadStoreV2 {
  Future<LogicalDownloadRecordV2?> get(DownloadLogicalId id);
  Future<List<LogicalDownloadRecordV2>> all();
  Future<void> put(LogicalDownloadRecordV2 record);
  Future<void> remove(DownloadLogicalId id);
  Future<LogicalDownloadRecordV2?> mutate(
    DownloadLogicalId id,
    LogicalDownloadRecordV2? Function(LogicalDownloadRecordV2? current) change,
  );
}

const String kLogicalDownloadStoreV2Box = 'logical_download_store_v2';
const int kLogicalDownloadSchemaV2 = 1;
```

The Hive backend stores `Map<String, Object?>` records keyed by `logicalId.value`. Serialize only fields defined in Task 1.

- [ ] **Step 4: Run focused tests**

Run: `flutter test test/core/services/download_v2/logical_download_store_v2_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/services/download_v2/logical_download_store_v2.dart test/core/services/download_v2/logical_download_store_v2_test.dart
git commit -m "feat(downloads): add v2 logical store"
```

---

### Task 3: Mockable BackgroundDownloaderGateway and 9.6.2 Contract

**Files:**
- Create: `lib/core/services/download_v2/background_downloader_gateway.dart`
- Create: `test/core/services/download_v2/background_downloader_gateway_test.dart`
- Create: `test/core/services/download_v2/background_downloader_api_contract_test.dart`

**Interfaces:**
- Consumes: package-neutral transport types from Task 1.
- Produces: `DownloadTaskSpecV2`, `DownloadTransportHandle`, `BackgroundDownloaderGateway`, `PackageBackgroundDownloaderGateway`.

- [ ] **Step 1: Write gateway contract tests before implementation**

```dart
test('gateway spec never exposes package chunk ids', () {
  const spec = DownloadTaskSpecV2(
    taskId: 'aw_v2_x_g1',
    url: 'https://example.invalid/video.mp4',
    headers: {'Referer': 'https://example.invalid/'},
    destinationPath: 'downloads/a.mp4',
    allowPause: true,
    retries: 2,
    parallelChunks: 5,
  );
  expect(spec.taskId, 'aw_v2_x_g1');
  expect(spec.parallelChunks, 5);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/services/download_v2/background_downloader_gateway_test.dart test/core/services/download_v2/background_downloader_api_contract_test.dart`

Expected: FAIL because the gateway is absent.

- [ ] **Step 3: Implement package-neutral gateway interface**

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
  Stream<DownloadTransportSnapshot> get snapshots;
  DownloadTransportSnapshot get current;
  Future<bool> pause();
  Future<bool> resume();
  Future<bool> cancel();
}
```

The concrete adapter must call `FileDownloader().start(autoCleanDatabase: true)` exactly once per process initialization; use `FileDownloader().transfers` for handles. Use package `DownloadTask` for `parallelChunks <= 1` and `ParallelDownloadTask` for `parallelChunks > 1`. Set `allowPause: true`, package retries, updates, priority, and destination fields from the spec. Never expose package child chunk tasks.

- [ ] **Step 4: Add compile-time API contract coverage for 9.6.2**

The contract test must instantiate/reference these public APIs so a package API change breaks CI:

```dart
final downloader = FileDownloader();
final Transfers transfers = downloader.transfers;
expect(transfers, isNotNull);
expect(FileDownloader().start, isA<Function>());
expect(transfers.start, isA<Function>());
expect(transfers.getOrStart, isA<Function>());
expect(transfers.rehydrateFromDatabase, isA<Function>());
```

- [ ] **Step 5: Run focused tests/analyzer and commit**

Run:

```bash
flutter test test/core/services/download_v2/background_downloader_gateway_test.dart test/core/services/download_v2/background_downloader_api_contract_test.dart
flutter analyze lib/core/services/download_v2
```

Expected: PASS.

Commit:

```bash
git add lib/core/services/download_v2/background_downloader_gateway.dart test/core/services/download_v2/background_downloader_gateway_test.dart test/core/services/download_v2/background_downloader_api_contract_test.dart
git commit -m "feat(downloads): add background downloader v2 gateway"
```

---

### Task 4: DownloadManagerV2 Start, Coalescing, and Generation Fence

**Files:**
- Create: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_manager_v2_start_test.dart`
- Create: `test/core/services/download_v2/download_manager_v2_generation_test.dart`

**Interfaces:**
- Consumes: logical store and gateway.
- Produces: `DownloadManagerV2.start`, `DownloadManagerV2.observe`, event-generation filtering.

- [ ] **Step 1: Write RED tests for duplicate start and stale events**

```dart
test('two start calls coalesce to one current generation', () async {
  final fixture = managerFixture();
  await Future.wait([
    fixture.manager.start(fixture.request),
    fixture.manager.start(fixture.request),
  ]);
  expect(fixture.gateway.startedSpecs, hasLength(1));
  expect((await fixture.store.all()).single.generation, 1);
});

test('old generation callback cannot overwrite replacement generation', () async {
  final fixture = managerFixture();
  await fixture.manager.start(fixture.request);
  await fixture.manager.restart(fixture.request.logicalId);
  fixture.gateway.emit(taskId: fixture.gateway.startedSpecs.first.taskId, status: DownloadTransportStatus.complete);
  expect(fixture.manager.snapshotFor(fixture.request.logicalId).status, isNot(DownloadTransportStatus.complete));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/services/download_v2/download_manager_v2_start_test.dart test/core/services/download_v2/download_manager_v2_generation_test.dart`

- [ ] **Step 3: Implement serialized per-logical-ID commands and generation checks**

```dart
Future<T> _serialize<T>(DownloadLogicalId id, Future<T> Function() body) {
  final previous = _tails[id.value] ?? Future<void>.value();
  final completer = Completer<T>();
  _tails[id.value] = previous.then((_) async {
    try {
      completer.complete(await body());
    } catch (error, stack) {
      completer.completeError(error, stack);
    }
  });
  return completer.future;
}

bool _isCurrent(LogicalDownloadRecordV2 record, String taskId) =>
    record.taskId == taskId && taskId == taskIdForGeneration(record.logicalId, record.generation);
```

Start must persist the new generation/task ID before accepting package callbacks. A duplicate start on active current work attaches/coalesces; it must not allocate generation 2.

- [ ] **Step 4: Run tests and commit**

```bash
flutter test test/core/services/download_v2/download_manager_v2_start_test.dart test/core/services/download_v2/download_manager_v2_generation_test.dart
git add lib/core/services/download_v2/download_manager_v2.dart test/core/services/download_v2/download_manager_v2_start_test.dart test/core/services/download_v2/download_manager_v2_generation_test.dart
git commit -m "feat(downloads): add v2 start and generation fencing"
```

---

### Task 5: Pause, Resume, Cancel, and Delete Semantics

**Files:**
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_manager_v2_lifecycle_test.dart`

**Interfaces:**
- Produces: `pause`, `resume`, `cancel`, `delete` lifecycle methods.

- [ ] **Step 1: Write RED lifecycle tests**

Required cases:

```dart
test('pause persists intent before gateway pause', () async {
  final fixture = managerFixture();
  await fixture.manager.start(fixture.request);
  fixture.gateway.onPause = () async {
    expect((await fixture.store.get(fixture.request.logicalId))?.intent, DownloadUserIntent.paused);
    return true;
  };
  await fixture.manager.pause(fixture.request.logicalId);
});

test('resume missing handle creates one fresh generation', () async {
  final fixture = pausedFixtureWithoutHandle();
  await fixture.manager.resume(fixture.logicalId);
  expect(fixture.gateway.startedSpecs.single.taskId, endsWith('_g2'));
});

test('cancel fences late complete event', () async {
  final fixture = managerFixture();
  await fixture.manager.start(fixture.request);
  final oldTaskId = fixture.gateway.startedSpecs.single.taskId;
  await fixture.manager.cancel(fixture.request.logicalId);
  fixture.gateway.emit(taskId: oldTaskId, status: DownloadTransportStatus.complete);
  expect((await fixture.store.get(fixture.request.logicalId))?.intent, DownloadUserIntent.canceled);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/services/download_v2/download_manager_v2_lifecycle_test.dart`

- [ ] **Step 3: Implement exact ordering rules**

Pause order:

```dart
record = record.copyWith(intent: DownloadUserIntent.paused, updatedAtMillis: clock());
await store.put(record);
final handle = handles[record.taskId] ?? await gateway.attach(record.taskId);
final paused = handle != null && await handle.pause();
if (!paused && handle != null) await handle.cancel();
```

Cancel/delete must advance generation or replace task identity before cancellation cleanup so the old callback is stale immediately. Resume sets active intent only within the serialized accepted command; if no resumable handle exists, it resolves a new source in Task 7 and starts a new generation.

- [ ] **Step 4: Run test and commit**

```bash
flutter test test/core/services/download_v2/download_manager_v2_lifecycle_test.dart
git add lib/core/services/download_v2/download_manager_v2.dart test/core/services/download_v2/download_manager_v2_lifecycle_test.dart
git commit -m "feat(downloads): implement v2 lifecycle commands"
```

---

### Task 6: Startup Rehydration and Relaunch Recovery

**Files:**
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_manager_v2_startup_test.dart`

**Interfaces:**
- Produces: `DownloadManagerV2.initialize()` and deterministic startup recovery.

- [ ] **Step 1: Write RED startup matrix**

```dart
final cases = <({DownloadUserIntent intent, bool hasHandle, int starts})>[
  (intent: DownloadUserIntent.paused, hasHandle: false, starts: 0),
  (intent: DownloadUserIntent.canceled, hasHandle: false, starts: 0),
  (intent: DownloadUserIntent.active, hasHandle: true, starts: 0),
  (intent: DownloadUserIntent.active, hasHandle: false, starts: 1),
];
```

Also assert rehydrated handles are bound only by exact `taskId`; same URL with another task ID is ignored.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/services/download_v2/download_manager_v2_startup_test.dart`

- [ ] **Step 3: Implement startup algorithm**

```dart
await gateway.initialize();
final rehydrated = {for (final h in await gateway.rehydrate()) h.taskId: h};
for (final record in await store.all()) {
  final handle = rehydrated[record.taskId];
  if (record.intent == DownloadUserIntent.paused || record.intent == DownloadUserIntent.canceled) {
    if (handle != null) _bind(record, handle);
    continue;
  }
  if (handle != null && !handle.current.isFinal) {
    _bind(record, handle);
  } else if (record.completedAtMillis == null) {
    await _startFreshGeneration(record.logicalId, reason: FreshStartReason.missingTransport);
  }
}
```

Use per-logical-ID serialization so concurrent startup and UI commands cannot create two generations.

- [ ] **Step 4: Run tests and commit**

```bash
flutter test test/core/services/download_v2/download_manager_v2_startup_test.dart
git add lib/core/services/download_v2/download_manager_v2.dart test/core/services/download_v2/download_manager_v2_startup_test.dart
git commit -m "feat(downloads): add deterministic v2 startup recovery"
```

---

### Task 7: Fresh Source Resolution and Signed-URL Failure Recovery

**Files:**
- Create: `lib/core/services/download_v2/download_source_resolver_v2.dart`
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_source_resolver_v2_test.dart`
- Create: `test/core/services/download_v2/download_manager_v2_source_refresh_test.dart`

**Interfaces:**
- Produces: `ResolvedDownloadSourceV2`, `DownloadSourceResolverV2.resolve`, source-expiry classification.

- [ ] **Step 1: Write RED tests for fresh source and one-shot refresh**

```dart
test('403 on current generation resolves once and replaces generation', () async {
  final fixture = managerFixtureWithResolver(urls: ['https://cdn/old', 'https://cdn/new']);
  await fixture.manager.start(fixture.request);
  fixture.gateway.failCurrentHttp(403);
  await fixture.manager.waitForIdle(fixture.request.logicalId);
  expect(fixture.resolver.resolveCount, 2);
  expect(fixture.gateway.startedSpecs, hasLength(2));
  expect(fixture.gateway.startedSpecs.last.url, 'https://cdn/new');
  expect(fixture.gateway.startedSpecs.last.taskId, isNot(fixture.gateway.startedSpecs.first.taskId));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/services/download_v2/download_source_resolver_v2_test.dart test/core/services/download_v2/download_manager_v2_source_refresh_test.dart`

- [ ] **Step 3: Implement source adapter and failure classifier**

```dart
final class ResolvedDownloadSourceV2 {
  const ResolvedDownloadSourceV2({required this.url, this.headers = const {}, this.expectedBytes});
  final String url;
  final Map<String, String> headers;
  final int? expectedBytes;
}

abstract interface class DownloadSourceResolverV2 {
  Future<ResolvedDownloadSourceV2> resolve(Map<String, Object?> sourceDescriptor);
}
```

Only `TaskHttpException` authorization/expiry codes defined by the adapter (at minimum 401/403) trigger source refresh. Fence the old generation, cancel/remove it, resolve once inside the serialized logical command, then start a byte-zero generation. No partial-byte adoption.

- [ ] **Step 4: Run tests and commit**

```bash
flutter test test/core/services/download_v2/download_source_resolver_v2_test.dart test/core/services/download_v2/download_manager_v2_source_refresh_test.dart
git add lib/core/services/download_v2/download_source_resolver_v2.dart lib/core/services/download_v2/download_manager_v2.dart test/core/services/download_v2
git commit -m "feat(downloads): add v2 signed source recovery"
```

---

### Task 8: Final-File Integrity Gate

**Files:**
- Create: `lib/core/services/download_v2/download_integrity_verifier_v2.dart`
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_integrity_verifier_v2_test.dart`
- Create: `test/core/services/download_v2/download_manager_v2_completion_test.dart`

**Interfaces:**
- Produces: `DownloadIntegrityVerifierV2.verify`, `DownloadIntegrityResult`.

- [ ] **Step 1: Write RED completion tests**

```dart
test('package complete is not logical complete until verification passes', () async {
  final fixture = managerFixture(integrity: const FakeIntegrity(valid: false));
  await fixture.manager.start(fixture.request);
  fixture.gateway.completeCurrent();
  await fixture.manager.waitForIdle(fixture.request.logicalId);
  final record = await fixture.store.get(fixture.request.logicalId);
  expect(record?.completedAtMillis, isNull);
  expect(record?.failureCategory, DownloadFailureCategory.integrity);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/services/download_v2/download_integrity_verifier_v2_test.dart test/core/services/download_v2/download_manager_v2_completion_test.dart`

- [ ] **Step 3: Implement final-file checks**

```dart
Future<DownloadIntegrityResult> verify({required File file, int? expectedBytes}) async {
  if (!await file.exists()) return const DownloadIntegrityResult.invalid('missing');
  final length = await file.length();
  if (length <= 0) return const DownloadIntegrityResult.invalid('empty');
  if (expectedBytes != null && expectedBytes > 0 && length != expectedBytes) {
    return DownloadIntegrityResult.invalid('size:$length/$expectedBytes');
  }
  return DownloadIntegrityResult.valid(length);
}
```

Only after valid result may `completedAtMillis` be committed.

- [ ] **Step 4: Run and commit**

```bash
flutter test test/core/services/download_v2/download_integrity_verifier_v2_test.dart test/core/services/download_v2/download_manager_v2_completion_test.dart
git add lib/core/services/download_v2 test/core/services/download_v2
git commit -m "feat(downloads): gate v2 completion on integrity"
```

---

### Task 9: Package-Managed Parallelism and Concurrency Mapping

**Files:**
- Modify: `lib/core/services/download_v2/background_downloader_gateway.dart`
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Create: `test/core/services/download_v2/download_v2_parallel_test.dart`

**Interfaces:**
- Consumes: existing user parallel/chunk and concurrent-episode settings.
- Produces: parent-only package task configuration.

- [ ] **Step 1: Write RED tests for parent-only parallel mapping**

```dart
test('five chunks becomes one package parallel parent spec', () async {
  final gateway = RecordingPackageGateway();
  await gateway.start(const DownloadTaskSpecV2(
    taskId: 'aw_v2_x_g1',
    url: 'https://cdn/video',
    destinationPath: 'downloads/video.mp4',
    allowPause: true,
    retries: 2,
    parallelChunks: 5,
  ));
  expect(gateway.parentTasks, hasLength(1));
  expect(gateway.persistedChildIds, isEmpty);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/services/download_v2/download_v2_parallel_test.dart`

- [ ] **Step 3: Map only documented package features**

Use `ParallelDownloadTask` for accepted chunk counts and package configuration/holding queues for concurrent episodes. Do not create Future-chain writer pools or custom chunk progress storage. If package-parallel is disabled by acceptance policy on a platform, construct a regular package `DownloadTask` with the same parent task ID contract.

- [ ] **Step 4: Run and commit**

```bash
flutter test test/core/services/download_v2/download_v2_parallel_test.dart
git add lib/core/services/download_v2/background_downloader_gateway.dart lib/core/services/download_v2/download_manager_v2.dart test/core/services/download_v2/download_v2_parallel_test.dart
git commit -m "feat(downloads): map v2 parallelism to package tasks"
```

---

### Task 10: Legacy Migration Policy A

**Files:**
- Create: `lib/core/services/download_v2/legacy_download_migration_v2.dart`
- Create: `test/core/services/download_v2/legacy_download_migration_v2_test.dart`

**Interfaces:**
- Produces: `LegacyDownloadMigrationV2.scan`, `.restartIncomplete`; `LegacyMigrationResult`.

- [ ] **Step 1: Write RED migration tests**

```dart
test('completed legacy item is preserved without new network work', () async {
  final fixture = legacyFixture(completed: true);
  final result = await fixture.migration.scan();
  expect(result.completedPreserved, 1);
  expect(fixture.gateway.startedSpecs, isEmpty);
});

test('incomplete legacy item imports no transport state and restarts at generation 1 on user resume', () async {
  final fixture = legacyFixture(completed: false, legacyBytes: 9000000);
  await fixture.migration.scan();
  expect(fixture.gateway.startedSpecs, isEmpty);
  await fixture.migration.restartIncomplete(fixture.logicalId);
  expect(fixture.gateway.startedSpecs.single.taskId, endsWith('_g1'));
  expect(fixture.gateway.startedSpecs.single.resumeOffset, isNull);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/services/download_v2/legacy_download_migration_v2_test.dart`

- [ ] **Step 3: Implement migration using only legacy presentation/file metadata**

Migration may read existing metadata to identify logical episode and completed path. It must not reconstruct `PersistentParallelDownload`, ranges, child IDs, ownership, or resume offsets. Incomplete rows become restart-required presentation records until explicit user action.

- [ ] **Step 4: Run and commit**

```bash
flutter test test/core/services/download_v2/legacy_download_migration_v2_test.dart
git add lib/core/services/download_v2/legacy_download_migration_v2.dart test/core/services/download_v2/legacy_download_migration_v2_test.dart
git commit -m "feat(downloads): add v2 legacy restart migration"
```

---

### Task 11: Riverpod Compatibility Adapter and Structured Diagnostics

**Files:**
- Create: `lib/core/services/download_v2/download_v2_provider.dart`
- Create: `lib/core/services/download_v2/download_v2_diagnostics.dart`
- Create: `test/core/services/download_v2/download_v2_provider_test.dart`
- Create: `test/core/services/download_v2/download_v2_diagnostics_test.dart`

**Interfaces:**
- Produces: keepAlive manager/provider, UI-facing snapshot stream/map, sanitized diagnostics.

- [ ] **Step 1: Write RED provider/log tests**

```dart
test('diagnostics never include signed url query values', () {
  final event = DownloadDiagnosticEventV2.sourceRefresh(
    logicalId: const DownloadLogicalId('x'),
    generation: 2,
    taskId: 'aw_v2_x_g2',
    reason: 'http403',
  );
  final json = event.toJson().toString();
  expect(json, isNot(contains('token=')));
  expect(json, isNot(contains('https://')));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/services/download_v2/download_v2_provider_test.dart test/core/services/download_v2/download_v2_diagnostics_test.dart`

- [ ] **Step 3: Implement provider construction**

Provider wiring must inject concrete Hive store, package gateway, source resolver, integrity verifier, diagnostics, and clock. UI projection comes from manager snapshots; UI must not read package database directly.

- [ ] **Step 4: Run and commit**

```bash
flutter test test/core/services/download_v2/download_v2_provider_test.dart test/core/services/download_v2/download_v2_diagnostics_test.dart
git add lib/core/services/download_v2 test/core/services/download_v2
git commit -m "feat(downloads): expose v2 manager to presentation"
```

---

### Task 12: Controlled Production Cutover Without Dual Writers

**Files:**
- Modify: `lib/main.dart`
- Modify: concrete existing download UI/provider call sites found by code search at execution time.
- Create: `test/core/services/download_v2/download_v2_cutover_guard_test.dart`

**Interfaces:**
- Produces: exactly one manager selected per logical download; all new production starts use V2.

- [ ] **Step 1: Add RED architectural guard tests**

The guard scans V2 imports/source and asserts no forbidden transport dependencies:

```dart
for (final forbidden in [
  'persistent_parallel_download.dart',
  'download_range_transfer.dart',
  'DownloadRangeTransfer(',
  'PersistentParallelDownload(',
]) {
  expect(v2Source, isNot(contains(forbidden)));
}
```

Add a cutover test proving one UI start action invokes exactly one manager path.

- [ ] **Step 2: Verify RED before routing changes**

Run: `flutter test test/core/services/download_v2/download_v2_cutover_guard_test.dart`

- [ ] **Step 3: Switch new downloads to V2**

Initialize package tracking once during app startup, initialize `DownloadManagerV2`, route start/pause/resume/cancel/delete and UI projection through the V2 provider. Legacy completed downloads remain readable. Legacy incomplete resume invokes Task 10 migration restart. Do not allow V1 fallback after a logical item is V2-owned.

- [ ] **Step 4: Run focused and broad automated suites**

```bash
flutter test test/core/services/download_v2
flutter analyze
flutter test
```

Expected: all pass before the cutover task is checked off.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart lib test/core/services/download_v2
git commit -m "refactor(downloads): route production downloads through v2"
```

---

### Task 13: Native Presentation Cleanup and Automated Regression Matrix

**Files:**
- Modify: `ios/Runner/AppDelegate.swift` only where transport-authority callbacks are now obsolete.
- Modify: existing native continued-processing bridge files only to remove enqueue/split/retry/resume/cancel authority from V2 path.
- Create/modify: V2 regression tests under `test/core/services/download_v2/`.

**Interfaces:**
- Produces: native observers are presentation-only; Dart/package remains transport authority.

- [ ] **Step 1: Add regression tests for the full automated lifecycle matrix**

Required automated cases: start, duplicate start, pause, resume, pause+manager recreation, active+missing transport recovery, network hold projection, source 403 refresh, cancel/delete late callback, integrity failure, five-chunk parent mapping, concurrent episodes, legacy completed preserve, legacy incomplete restart.

- [ ] **Step 2: Remove native authority from V2 path**

Native code may emit presentation telemetry/status but must not independently start, split, retry, resume, or cancel V2 tasks. Remove any V2 hookup that would create a second executor.

- [ ] **Step 3: Run full verification**

```bash
flutter analyze
flutter test
```

Also rely on PR CI for platform build/contract checks.

- [ ] **Step 4: Commit**

```bash
git add ios lib test
git commit -m "refactor(downloads): remove native transport authority from v2"
```

---

### Task 14: Physical-Device Acceptance Gate

**Files:**
- Create/modify: `docs/superpowers/plans/2026-09-17-download-manager-v2.md` with recorded evidence under this task.

**Interfaces:**
- Produces: explicit real-device evidence required before V1 deletion.

- [ ] **Step 1: Run iOS and Android acceptance**

Record exact build/run identifiers and results for:

1. new download complete;
2. pause -> resume;
3. pause -> kill -> relaunch stays paused -> resume;
4. running -> termination/background -> relaunch reattach/recover;
5. network loss/recovery;
6. 401/403 fresh-source byte-zero generation;
7. package parallel at 5 chunks and other user-relevant settings;
8. multiple concurrent episodes;
9. cancel during transfer;
10. delete during/after transfer;
11. disk-space failure;
12. integrity failure;
13. stale callback from replaced generation;
14. completed legacy playback;
15. incomplete legacy restart from byte zero.

- [ ] **Step 2: Do not mark this task complete without device evidence**

CI/mocks may support the implementation but cannot satisfy this gate.

- [ ] **Step 3: Commit recorded evidence only after completion**

```bash
git add docs/superpowers/plans/2026-09-17-download-manager-v2.md
git commit -m "test(downloads): record v2 device acceptance"
```

---

### Task 15: Remove V1 Transport/Ownership Machinery

**Prerequisite:** Task 14 complete on required physical devices.

**Files:**
- Delete or reduce obsolete V1 files including `lib/core/services/persistent_parallel_download.dart`, `lib/core/services/download_range_transfer.dart`, obsolete V1 ownership/job-state/transport files, and tests that only verify removed architecture.
- Modify: `lib/core/services/download_service.dart` or remove it if no remaining non-download responsibilities require it.
- Modify: UI imports/providers to remove temporary compatibility layer pieces no longer needed.

**Interfaces:**
- Produces: V2 is the only production downloader implementation.

- [ ] **Step 1: Prove V1 is unreachable before deletion**

Use code search plus an architectural test that fails if production imports obsolete V1 executor types.

- [ ] **Step 2: Delete obsolete transport implementation and update imports**

Delete only files proven unreachable; preserve generic utilities still used outside transport. Do not delete legacy completed-download metadata readers until migration/playback no longer needs them.

- [ ] **Step 3: Run complete verification**

```bash
flutter analyze
flutter test
```

PR CI must be green across configured platform checks.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(downloads): remove legacy downloader transport"
```

---

### Task 16: Final Code Review and Merge Readiness

**Files:**
- Modify this plan only for final checkbox/evidence updates if needed.

- [ ] **Step 1: Compare the finished PR against the design spec section-by-section**

Verify every acceptance criterion in spec section 19 maps to implementation plus evidence.

- [ ] **Step 2: Run final verification from the PR head**

```bash
flutter analyze
flutter test
```

Fetch PR CI for the exact head SHA and inspect any failure rather than relying on older runs.

- [ ] **Step 3: Deep review the final diff**

Check especially: duplicate writers, pause persistence ordering, generation fencing, startup auto-recovery, signed URL loops, final integrity, legacy policy A, and forbidden V1 fallback.

- [ ] **Step 4: Fix every discovered regression and rerun verification**

No task is complete merely because a previous commit was green.

- [ ] **Step 5: Mark PR ready only when all non-device and device gates are actually satisfied**

Do not merge automatically unless explicitly requested.
