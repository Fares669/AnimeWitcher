import 'dart:async';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_v2_test_support.dart';

void main() {
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
    gateway.addRehydrated(record.taskId, DownloadTransportStatus.running);
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
  final List<String> attachCalls = <String>[];
  final Map<String, _StartupHandle> _rehydrated = <String, _StartupHandle>{};

  void addRehydrated(String taskId, DownloadTransportStatus status) {
    _rehydrated[taskId] = _StartupHandle(
      DownloadTransportSnapshot(taskId: taskId, status: status, progress: 0.5),
    );
  }

  @override
  Future<void> initialize() async {}

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

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  @override
  Future<bool> pause() async {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.paused,
      progress: _current.progress,
    );
    return true;
  }

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async => true;
}
