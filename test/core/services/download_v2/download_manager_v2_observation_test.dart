import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_v2_test_support.dart';

void main() {
  test('records exposes logical state and completed availability verifies disk', () async {
    final temp = await Directory.systemTemp.createTemp('aw-v2-observe-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}${Platform.pathSeparator}episode.mp4');
    await file.writeAsBytes(<int>[1, 2, 3, 4]);
    final id = logicalDownloadIdFor(
      animeId: 'anime:1',
      episodeKey: '1',
      variantKey: 'sub:1080p',
    );
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(
      _record(
        id: id,
        destinationPath: file.path,
        completedAtMillis: 100,
        expectedBytes: 4,
      ),
    );
    final gateway = _Gateway();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: StaticSourceResolverV2(),
    );
    addTearDown(manager.dispose);

    final records = await manager.records.first;

    expect(records.map((record) => record.logicalId), contains(id));
    expect(await manager.hasCompletedDownload(id), isTrue);
    expect(gateway.startedSpecs, isEmpty);

    await file.delete();
    expect(await manager.hasCompletedDownload(id), isFalse);
  });

  test('native speed overlay preserves configured and active connection telemetry', () async {
    final id = logicalDownloadIdFor(
      animeId: 'anime:1',
      episodeKey: 'metrics',
      variantKey: 'sub:1080p',
    );
    final taskId = taskIdForGeneration(id, 1);
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(
      _record(
        id: id,
        destinationPath: 'downloads/metrics.mp4',
        expectedBytes: 100,
        parallelChunks: 16,
      ),
    );
    final handle = _Handle(
      taskId,
      initial: DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: .50,
        // Durable checkpoint may lag behind in-flight parent progress.
        transferredBytes: 25,
        totalBytes: 100,
        configuredConnections: 16,
        activeConnections: 4,
      ),
    );
    final gateway = _Gateway(rehydrated: <DownloadTransportHandle>[handle]);
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: StaticSourceResolverV2(),
    );
    addTearDown(manager.dispose);

    await manager.initialize();
    manager.observeNativeNetworkSpeed(
      taskId: taskId,
      bytesPerSecond: 5 * 1000 * 1000,
    );

    var snapshot = manager.snapshotFor(id);
    expect(snapshot?.networkSpeedMBps, 5);
    expect(
      snapshot?.transferredBytes,
      50,
      reason:
          'presentation bytes must not regress to an older durable checkpoint '
          'while parent progress already proves more bytes transferred',
    );
    expect(snapshot?.configuredConnections, 16);
    expect(snapshot?.activeConnections, 4);

    handle.emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: .5,
        transferredBytes: 50,
        totalBytes: 100,
        configuredConnections: 16,
        activeConnections: 8,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    snapshot = manager.snapshotFor(id);
    expect(snapshot?.networkSpeedMBps, 5);
    expect(snapshot?.configuredConnections, 16);
    expect(snapshot?.activeConnections, 8);
  });

  test('native speed telemetry is projected at most once per second', () async {
    var now = 1000;
    final id = logicalDownloadIdFor(
      animeId: 'anime:1',
      episodeKey: 'native-speed-coalesce',
      variantKey: 'sub:1080p',
    );
    final taskId = taskIdForGeneration(id, 1);
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(
      _record(
        id: id,
        destinationPath: 'downloads/native-speed-coalesce.mp4',
        expectedBytes: 100,
        parallelChunks: 16,
      ),
    );
    final handle = _Handle(
      taskId,
      initial: DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: .5,
        transferredBytes: 50,
        totalBytes: 100,
        configuredConnections: 16,
        activeConnections: 16,
      ),
    );
    final diagnostics = InMemoryDownloadDiagnosticsV2();
    final manager = DownloadManagerV2(
      store: store,
      gateway: _Gateway(rehydrated: <DownloadTransportHandle>[handle]),
      sourceResolver: StaticSourceResolverV2(),
      diagnostics: diagnostics,
      nowMillis: () => now,
    );
    addTearDown(manager.dispose);

    await manager.initialize();
    final baseline = diagnostics.events.length;

    manager.observeNativeNetworkSpeed(
      taskId: taskId,
      bytesPerSecond: 4 * 1000 * 1000,
    );
    manager.observeNativeNetworkSpeed(
      taskId: taskId,
      bytesPerSecond: 8 * 1000 * 1000,
    );

    expect(
      diagnostics.events.length - baseline,
      1,
      reason:
          '16 child callbacks can arrive in one burst; speed-only telemetry '
          'must not create one parent snapshot and log flush per child.',
    );
    expect(manager.snapshotFor(id)?.networkSpeedMBps, 4);

    now += 1000;
    manager.observeNativeNetworkSpeed(
      taskId: taskId,
      bytesPerSecond: 8 * 1000 * 1000,
    );

    expect(diagnostics.events.length - baseline, 2);
    expect(manager.snapshotFor(id)?.networkSpeedMBps, 8);
  });

  test('parallel zero-speed handoff keeps the last fresh positive speed', () async {
    var now = 1000;
    final id = logicalDownloadIdFor(
      animeId: 'anime:1',
      episodeKey: 'speed-handoff',
      variantKey: 'sub:1080p',
    );
    final taskId = taskIdForGeneration(id, 1);
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(
      _record(
        id: id,
        destinationPath: 'downloads/speed-handoff.mp4',
        expectedBytes: 100,
        parallelChunks: 16,
      ),
    );
    final handle = _Handle(
      taskId,
      initial: DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: .4,
        transferredBytes: 40,
        totalBytes: 100,
        networkSpeedMBps: 2,
        configuredConnections: 16,
        activeConnections: 8,
      ),
    );
    final manager = DownloadManagerV2(
      store: store,
      gateway: _Gateway(rehydrated: <DownloadTransportHandle>[handle]),
      sourceResolver: StaticSourceResolverV2(),
      nowMillis: () => now,
    );
    addTearDown(manager.dispose);

    await manager.initialize();
    manager.observeNativeNetworkSpeed(
      taskId: taskId,
      bytesPerSecond: 2 * 1000 * 1000,
    );

    handle.emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: .41,
        transferredBytes: 41,
        totalBytes: 100,
        networkSpeedMBps: 0,
        configuredConnections: 16,
        activeConnections: 8,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(manager.snapshotFor(id)?.networkSpeedMBps, 2);

    now += 4000;
    handle.emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: .41,
        transferredBytes: 41,
        totalBytes: 100,
        networkSpeedMBps: 0,
        configuredConnections: 16,
        activeConnections: 8,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(manager.snapshotFor(id)?.networkSpeedMBps, 0);
  });

  test('records stream cannot lose a start between initial snapshot and subscription', () async {
    final store = _RaceStore();
    final gateway = _Gateway();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: StaticSourceResolverV2(expectedBytes: 100),
    );
    addTearDown(manager.dispose);
    await manager.initialize();

    store.blockNextAll();
    final emissions = <List<LogicalDownloadRecordV2>>[];
    final subscription = manager.records.listen(emissions.add);
    addTearDown(subscription.cancel);
    await store.blockEntered.future;

    final id = logicalDownloadIdFor(
      animeId: 'anime:race',
      episodeKey: '1',
      variantKey: 'sub:1080p',
    );
    final start = manager.start(
      DownloadStartRequestV2(
        logicalId: id,
        animeId: 'anime:race',
        episodeKey: '1',
        variantKey: 'sub:1080p',
        destinationPath: 'downloads/race.mp4',
        sourceDescriptor: const <String, Object?>{'providerId': 'provider.example'},
        expectedBytes: 100,
        allowPause: true,
        retries: 2,
        parallelChunks: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    store.releaseBlockedAll();
    await start;

    for (var i = 0; i < 20 && !emissions.any((items) => items.any((r) => r.logicalId == id)); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(
      emissions.any((items) => items.any((record) => record.logicalId == id)),
      isTrue,
      reason:
          'a new V2 row must be visible without killing/reopening the app even '
          'when start races the records stream initial snapshot',
    );
  });

  test('startup recreation preserves five-part application policy', () async {
    final id = logicalDownloadIdFor(
      animeId: 'anime:1',
      episodeKey: '2',
      variantKey: 'sub:1080p',
    );
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(
      _record(
        id: id,
        destinationPath: 'downloads/episode-2.mp4',
        parallelChunks: 5,
        retries: 4,
      ),
    );
    final gateway = _Gateway();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: StaticSourceResolverV2(),
    );
    addTearDown(manager.dispose);

    await manager.initialize();

    expect(gateway.startedSpecs, hasLength(1));
    expect(gateway.startedSpecs.single.parallelChunks, 5);
    expect(gateway.startedSpecs.single.retries, 4);
  });
}

LogicalDownloadRecordV2 _record({
  required DownloadLogicalId id,
  required String destinationPath,
  int? completedAtMillis,
  int? expectedBytes,
  int parallelChunks = 1,
  int retries = 2,
}) {
  return LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: id,
    animeId: 'anime:1',
    episodeKey: 'episode',
    variantKey: 'sub:1080p',
    generation: 1,
    taskId: taskIdForGeneration(id, 1),
    intent: DownloadUserIntent.active,
    destinationPath: destinationPath,
    sourceDescriptor: const <String, Object?>{'providerId': 'provider.example'},
    expectedBytes: expectedBytes,
    completedAtMillis: completedAtMillis,
    allowPause: true,
    retries: retries,
    parallelChunks: parallelChunks,
    updatedAtMillis: 1,
  );
}

final class _RaceStore implements LogicalDownloadStoreV2 {
  final InMemoryLogicalDownloadStoreV2 _inner = InMemoryLogicalDownloadStoreV2();
  Completer<void> blockEntered = Completer<void>();
  Completer<void>? _release;
  bool _blockNext = false;

  void blockNextAll() {
    blockEntered = Completer<void>();
    _release = Completer<void>();
    _blockNext = true;
  }

  void releaseBlockedAll() => _release?.complete();

  @override
  Future<List<LogicalDownloadRecordV2>> all() async {
    if (!_blockNext) return _inner.all();
    _blockNext = false;
    final stale = await _inner.all();
    blockEntered.complete();
    await _release!.future;
    return stale;
  }

  @override
  Future<LogicalDownloadRecordV2?> get(DownloadLogicalId id) => _inner.get(id);

  @override
  Future<void> put(LogicalDownloadRecordV2 record) => _inner.put(record);

  @override
  Future<void> remove(DownloadLogicalId id) => _inner.remove(id);

  @override
  Future<LogicalDownloadRecordV2?> mutate(
    DownloadLogicalId id,
    LogicalDownloadRecordV2? Function(LogicalDownloadRecordV2? current) change,
  ) => _inner.mutate(id, change);
}

final class _Gateway implements BackgroundDownloaderGateway {
  _Gateway({this.rehydrated = const <DownloadTransportHandle>[]});

  final List<DownloadTaskSpecV2> startedSpecs = <DownloadTaskSpecV2>[];
  final List<DownloadTransportHandle> rehydrated;

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    startedSpecs.add(spec);
    return _Handle(spec.taskId);
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => rehydrated;

  @override
  Future<void> removeTracking(String taskId) async {}
}

final class _Handle implements DownloadTransportHandle {
  _Handle(this.taskId, {DownloadTransportSnapshot? initial})
    : _current =
          initial ??
          DownloadTransportSnapshot(
            taskId: taskId,
            status: DownloadTransportStatus.running,
            progress: 0,
          );

  @override
  final String taskId;
  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast();

  void emit(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    _controller.add(snapshot);
  }

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  @override
  Future<bool> cancel() async => true;

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;
}
