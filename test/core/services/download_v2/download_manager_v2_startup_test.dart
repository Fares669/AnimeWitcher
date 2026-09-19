import 'dart:async';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_v2_test_support.dart';

void main() {
  test('startup initialization can retry after one gateway failure', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _StartupGateway()..initializeFailuresRemaining = 1;
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: StaticSourceResolverV2(),
    );
    addTearDown(manager.dispose);

    await expectLater(manager.initialize(), throwsStateError);
    await manager.initialize();

    expect(gateway.initializeCalls, 2);
    expect(await store.all(), isEmpty);
  });

  test('startup never restarts paused intent without a handle', () async {
    final f = await _startupFixture(intent: DownloadUserIntent.paused);

    await f.manager.initialize();

    expect(f.gateway.startedSpecs, isEmpty);
    expect(f.resolver.calls, 0);
    expect(
      f.manager.snapshotFor(f.logicalId)?.status,
      DownloadTransportStatus.paused,
    );
  });

  test('explicit resume never recreates a missing paused generation', () async {
    final f = await _startupFixture(intent: DownloadUserIntent.paused);

    await f.manager.initialize();
    await expectLater(f.manager.resume(f.logicalId), throwsStateError);

    final stored = await f.store.get(f.logicalId);
    expect(f.gateway.startedSpecs, isEmpty);
    expect(f.resolver.calls, 0);
    expect(stored?.generation, 1);
    expect(stored?.taskId, f.record.taskId);
    expect(stored?.intent, DownloadUserIntent.paused);
    expect(
      f.manager.snapshotFor(f.logicalId)?.status,
      DownloadTransportStatus.paused,
    );
  });

  test('startup waits for paused transport settlement before completing', () async {
    final f = await _startupFixture(
      intent: DownloadUserIntent.paused,
      hasExactHandle: true,
    );
    final handle = f.gateway.handleFor(f.record.taskId)!;
    handle.onPause = () async => true;

    var initialized = false;
    final initializeFuture = f.manager.initialize().whenComplete(() {
      initialized = true;
    });
    await Future<void>.delayed(Duration.zero);

    expect(handle.pauseCalls, 1);
    expect(initialized, isFalse);

    handle.emitStatus(DownloadTransportStatus.paused);
    await initializeFuture;

    expect(initialized, isTrue);
    expect(
      f.manager.snapshotFor(f.logicalId)?.status,
      DownloadTransportStatus.paused,
    );
  });

  test('startup never recreates canceled intent', () async {
    final f = await _startupFixture(intent: DownloadUserIntent.canceled);

    await f.manager.initialize();

    expect(f.gateway.startedSpecs, isEmpty);
    expect(f.resolver.calls, 0);
    expect(
      f.manager.snapshotFor(f.logicalId)?.status,
      DownloadTransportStatus.canceled,
    );
  });

  test('startup resumes an exact paused transfer for active intent', () async {
    final f = await _startupFixture(
      intent: DownloadUserIntent.active,
      hasExactHandle: true,
      exactHandleStatus: DownloadTransportStatus.paused,
    );
    final handle = f.gateway.handleFor(f.record.taskId)!;

    await f.manager.initialize();

    expect(handle.resumeCalls, 1);
    expect(f.gateway.startedSpecs, isEmpty);
    expect(f.resolver.calls, 0);
    expect(
      f.manager.snapshotFor(f.logicalId)?.status,
      DownloadTransportStatus.running,
    );
  });

  test('startup binds exact active transfer without creating a writer', () async {
    final f = await _startupFixture(
      intent: DownloadUserIntent.active,
      hasExactHandle: true,
    );

    await f.manager.initialize();

    expect(f.gateway.startedSpecs, isEmpty);
    expect(f.resolver.calls, 0);
    expect(f.manager.snapshotFor(f.logicalId)?.taskId, f.record.taskId);
    expect(
      f.manager.snapshotFor(f.logicalId)?.status,
      DownloadTransportStatus.running,
    );
  });

  test('startup restarts active record with no recoverable exact transfer', () async {
    final f = await _startupFixture(intent: DownloadUserIntent.active);

    await f.manager.initialize();

    expect(f.gateway.startedSpecs, hasLength(1));
    expect(f.resolver.calls, 1);
    expect(f.gateway.startedSpecs.single.taskId, isNot(f.record.taskId));
    expect((await f.store.get(f.logicalId))?.generation, 2);
  });

  test('startup isolates one broken active record and recovers the rest', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _StartupGateway();
    final resolver = _SelectiveStartupResolver();

    LogicalDownloadRecordV2 record({
      required int anime,
      required int episode,
      required String providerId,
    }) {
      final logicalId = logicalDownloadIdFor(
        animeId: 'anilist:$anime',
        episodeKey: '$episode',
        variantKey: 'sub:1080p',
      );
      return LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: logicalId,
        animeId: 'anilist:$anime',
        episodeKey: '$episode',
        variantKey: 'sub:1080p',
        generation: 1,
        taskId: taskIdForGeneration(logicalId, 1),
        intent: DownloadUserIntent.active,
        destinationPath: 'downloads/anime/episode-$episode.mp4',
        sourceDescriptor: <String, Object?>{
          'providerId': providerId,
          'trackingUrl': '/anime/$anime/$episode',
        },
        expectedBytes: 100,
        updatedAtMillis: episode,
      );
    }

    final broken = record(
      anime: 21,
      episode: 12,
      providerId: 'provider.broken',
    );
    final healthy = record(
      anime: 22,
      episode: 13,
      providerId: 'provider.healthy',
    );
    await store.put(broken);
    await store.put(healthy);

    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    addTearDown(manager.dispose);

    await manager.initialize();

    expect(resolver.calls, 2);
    expect(
      gateway.startedSpecs.map((spec) => spec.destinationPath),
      contains(healthy.destinationPath),
    );
    expect(
      gateway.startedSpecs.map((spec) => spec.destinationPath),
      isNot(contains(broken.destinationPath)),
    );
    expect(
      manager.snapshotFor(broken.logicalId)?.status,
      DownloadTransportStatus.failed,
    );
    expect(
      manager.snapshotFor(healthy.logicalId)?.status,
      DownloadTransportStatus.running,
    );
  });

  test('startup keeps one canonical writer when duplicate active handles rehydrate', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _StartupGateway();
    final resolver = StaticSourceResolverV2(expectedBytes: 100);
    const destination = 'downloads/anime/shared-episode.mp4';

    LogicalDownloadRecordV2 record({
      required int anime,
      required int episode,
      required int updatedAtMillis,
    }) {
      final logicalId = logicalDownloadIdFor(
        animeId: 'anilist:$anime',
        episodeKey: '$episode',
        variantKey: 'sub:1080p',
      );
      return LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: logicalId,
        animeId: 'anilist:$anime',
        episodeKey: '$episode',
        variantKey: 'sub:1080p',
        generation: 1,
        taskId: taskIdForGeneration(logicalId, 1),
        intent: DownloadUserIntent.active,
        destinationPath: destination,
        sourceDescriptor: const <String, Object?>{
          'providerId': 'provider.example',
        },
        expectedBytes: 100,
        updatedAtMillis: updatedAtMillis,
      );
    }

    final first = record(anime: 21, episode: 12, updatedAtMillis: 1);
    final second = record(anime: 22, episode: 13, updatedAtMillis: 2);
    await store.put(first);
    await store.put(second);
    gateway.addRehydrated(first.taskId, DownloadTransportStatus.running);
    gateway.addRehydrated(second.taskId, DownloadTransportStatus.running);

    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    addTearDown(manager.dispose);

    await manager.initialize();

    expect(manager.snapshotFor(first.logicalId)?.status, DownloadTransportStatus.running);
    expect(manager.snapshotFor(second.logicalId)?.status, DownloadTransportStatus.paused);
    expect((await store.get(first.logicalId))?.intent, DownloadUserIntent.active);
    expect((await store.get(second.logicalId))?.intent, DownloadUserIntent.paused);
    expect(gateway.handleFor(first.taskId)?.pauseCalls, 0);
    expect(gateway.handleFor(second.taskId)?.pauseCalls, 1);
    expect(gateway.startedSpecs, isEmpty);
  });

  test('startup never adopts a different task id even when transport looks related', () async {
    final f = await _startupFixture(
      intent: DownloadUserIntent.active,
      hasDifferentHandle: true,
    );

    await f.manager.initialize();

    expect(f.gateway.startedSpecs, hasLength(1));
    expect(f.resolver.calls, 1);
    expect(f.gateway.startedSpecs.single.taskId, isNot('unrelated_same_source'));
    expect(f.gateway.attachCalls, isEmpty);
  });
}

Future<_StartupFixture> _startupFixture({
  required DownloadUserIntent intent,
  bool hasExactHandle = false,
  bool hasDifferentHandle = false,
  DownloadTransportStatus exactHandleStatus = DownloadTransportStatus.running,
}) async {
  final logicalId = logicalDownloadIdFor(
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
  );
  final record = LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: logicalId,
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
    generation: 1,
    taskId: taskIdForGeneration(logicalId, 1),
    intent: intent,
    destinationPath: 'downloads/anime/episode-12.mp4',
    sourceDescriptor: const <String, Object?>{
      'providerId': 'provider.example',
      'trackingUrl': '/anime/21/12',
    },
    expectedBytes: 100,
    updatedAtMillis: 1,
  );
  final store = InMemoryLogicalDownloadStoreV2();
  await store.put(record);
  final gateway = _StartupGateway();
  if (hasExactHandle) {
    gateway.addRehydrated(record.taskId, exactHandleStatus);
  }
  if (hasDifferentHandle) {
    gateway.addRehydrated(
      'unrelated_same_source',
      DownloadTransportStatus.running,
    );
  }
  final resolver = StaticSourceResolverV2(expectedBytes: 100);
  final manager = DownloadManagerV2(
    store: store,
    gateway: gateway,
    sourceResolver: resolver,
  );
  return _StartupFixture(
    logicalId: logicalId,
    record: record,
    store: store,
    gateway: gateway,
    resolver: resolver,
    manager: manager,
  );
}

final class _StartupFixture {
  const _StartupFixture({
    required this.logicalId,
    required this.record,
    required this.store,
    required this.gateway,
    required this.resolver,
    required this.manager,
  });

  final DownloadLogicalId logicalId;
  final LogicalDownloadRecordV2 record;
  final InMemoryLogicalDownloadStoreV2 store;
  final _StartupGateway gateway;
  final StaticSourceResolverV2 resolver;
  final DownloadManagerV2 manager;
}

final class _StartupGateway implements BackgroundDownloaderGateway {
  final List<DownloadTaskSpecV2> startedSpecs = <DownloadTaskSpecV2>[];
  int initializeFailuresRemaining = 0;
  int initializeCalls = 0;
  final List<String> attachCalls = <String>[];
  final Map<String, _StartupHandle> _rehydrated = <String, _StartupHandle>{};

  _StartupHandle? handleFor(String taskId) => _rehydrated[taskId];

  void addRehydrated(String taskId, DownloadTransportStatus status) {
    _rehydrated[taskId] = _StartupHandle(
      DownloadTransportSnapshot(taskId: taskId, status: status, progress: 0.5),
    );
  }

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (initializeFailuresRemaining > 0) {
      initializeFailuresRemaining--;
      throw StateError('transient gateway initialization failure');
    }
  }

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    startedSpecs.add(spec);
    final handle = _StartupHandle(
      DownloadTransportSnapshot(
        taskId: spec.taskId,
        status: DownloadTransportStatus.running,
        progress: 0,
      ),
    );
    _rehydrated[spec.taskId] = handle;
    return handle;
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async {
    attachCalls.add(taskId);
    return _rehydrated[taskId];
  }

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      _rehydrated.values.toList(growable: false);

  @override
  Future<void> removeTracking(String taskId) async {
    _rehydrated.remove(taskId);
  }
}

final class _StartupHandle implements DownloadTransportHandle {
  _StartupHandle(this._current);

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);
  Future<bool> Function()? onPause;
  int pauseCalls = 0;
  int resumeCalls = 0;

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  @override
  Future<bool> pause() async {
    pauseCalls++;
    final override = onPause;
    if (override != null) return override();
    emitStatus(DownloadTransportStatus.paused);
    return true;
  }

  void emitStatus(DownloadTransportStatus status) {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: status,
      progress: _current.progress,
    );
    _controller.add(_current);
  }

  @override
  Future<bool> resume() async {
    resumeCalls++;
    emitStatus(DownloadTransportStatus.running);
    return true;
  }

  @override
  Future<bool> cancel() async => true;
}

final class _SelectiveStartupResolver implements DownloadSourceResolverV2 {
  int calls = 0;

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    calls++;
    if (descriptor['providerId'] == 'provider.broken') {
      throw StateError('broken startup source');
    }
    return const ResolvedDownloadSourceV2(
      url: 'https://example.invalid/video.mp4',
      headers: <String, String>{},
      expectedBytes: 100,
    );
  }
}
