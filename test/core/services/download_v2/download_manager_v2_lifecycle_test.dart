import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_continued_processing_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_v2_test_support.dart';

void main() {
  test('accepted V2 snapshots are forwarded to presentation observers', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _FakeGateway();
    final resolver = StaticSourceResolverV2();
    final observer = _RecordingPresentationObserver();
    final logicalId = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );
    final request = DownloadStartRequestV2(
      logicalId: logicalId,
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
      destinationPath: 'downloads/anime/episode-12.mp4',
      sourceDescriptor: const <String, Object?>{
        'providerId': 'provider.example',
      },
      allowPause: true,
      retries: 2,
      parallelChunks: 1,
    );
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
      presentationObservers: <DownloadPresentationObserverV2>[observer],
    );
    addTearDown(manager.dispose);

    await manager.start(request);
    final taskId = gateway.startedSpecs.single.taskId;
    gateway.emit(taskId, DownloadTransportStatus.running);
    await Future<void>.delayed(Duration.zero);

    expect(observer.events, isNotEmpty);
    expect(observer.events.last.$1.logicalId, logicalId);
    expect(observer.events.last.$2.taskId, taskId);
    expect(observer.events.last.$2.status, DownloadTransportStatus.running);
  });

  test('native observed speed updates only the current V2 generation', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;

    f.manager.observeNativeNetworkSpeed(
      taskId: taskId,
      bytesPerSecond: 4_500_000,
    );

    expect(
      f.manager.snapshotFor(f.request.logicalId)?.networkSpeedMBps,
      4.5,
    );

    f.manager.observeNativeNetworkSpeed(
      taskId: taskId,
      bytesPerSecond: 0,
    );
    expect(
      f.manager.snapshotFor(f.request.logicalId)?.networkSpeedMBps,
      0,
    );

    await f.manager.cancel(f.request.logicalId);
    f.manager.observeNativeNetworkSpeed(
      taskId: taskId,
      bytesPerSecond: 99_000_000,
    );

    expect(
      f.manager.snapshotFor(f.request.logicalId)?.networkSpeedMBps,
      isNot(99.0),
    );
  });

  test('parallel parent progress does not erase native speed', () async {
    final f = _fixture(parallelChunks: 4);
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;

    f.manager.observeNativeNetworkSpeed(
      taskId: taskId,
      bytesPerSecond: 4_500_000,
    );
    handle.emitSnapshot(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: 0.5,
        transferredBytes: 50,
        totalBytes: 100,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final snapshot = f.manager.snapshotFor(f.request.logicalId);
    expect(snapshot?.progress, 0.5);
    expect(snapshot?.networkSpeedMBps, 4.5);
  });

  test('zero native speed clears ETA without dividing by zero', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _FakeGateway();
    final resolver = StaticSourceResolverV2();
    final logicalId = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );
    final request = DownloadStartRequestV2(
      logicalId: logicalId,
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
      destinationPath: 'downloads/anime/episode-12.mp4',
      sourceDescriptor: const <String, Object?>{
        'providerId': 'provider.example',
      },
      expectedBytes: 1000,
      allowPause: true,
      retries: 2,
      parallelChunks: 16,
    );
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    addTearDown(manager.dispose);

    await manager.start(request);
    final taskId = gateway.startedSpecs.single.taskId;
    gateway.handleFor(taskId)!.emitSnapshot(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: 0.5,
        transferredBytes: 500,
        totalBytes: 1000,
      ),
    );

    expect(
      () => manager.observeNativeNetworkSpeed(
        taskId: taskId,
        bytesPerSecond: 0,
      ),
      returnsNormally,
    );
    expect(manager.snapshotFor(logicalId)?.networkSpeedMBps, 0);
    expect(manager.snapshotFor(logicalId)?.timeRemaining, Duration.zero);
  });

  test('pause waits for package paused state before allowing exact resume', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;
    handle.onPause = () async => true;

    var pauseCompleted = false;
    final pauseFuture = f.manager.pause(f.request.logicalId).whenComplete(() {
      pauseCompleted = true;
    });
    await Future<void>.delayed(Duration.zero);

    expect(pauseCompleted, isFalse);
    expect(handle.pauseCalls, 1);

    f.gateway.emit(taskId, DownloadTransportStatus.paused);
    final paused = await pauseFuture;
    expect(paused?.status, DownloadTransportStatus.paused);

    final resumed = await f.manager.resume(f.request.logicalId);

    expect(resumed.taskId, taskId);
    expect(handle.resumeCalls, 1);
    expect(f.gateway.startedSpecs, hasLength(1));
    expect((await f.store.get(f.request.logicalId))?.generation, 1);
  });

  test('pause intent is durable before package pause', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final handle = f.gateway.handleFor(f.gateway.startedSpecs.single.taskId)!;
    handle.onPause = () async {
      expect(
        (await f.store.get(f.request.logicalId))?.intent,
        DownloadUserIntent.paused,
      );
      return true;
    };

    await f.manager.pause(f.request.logicalId);

    expect(handle.pauseCalls, 1);
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.paused,
    );
  });

  test('rejects a second logical writer for the same canonical destination', () async {
    final f = _fixture();
    final conflicting = DownloadStartRequestV2(
      logicalId: logicalDownloadIdFor(
        animeId: 'anilist:22',
        episodeKey: '13',
        variantKey: 'sub:1080p',
      ),
      animeId: 'anilist:22',
      episodeKey: '13',
      variantKey: 'sub:1080p',
      destinationPath: f.request.destinationPath,
      sourceDescriptor: const <String, Object?>{
        'providerId': 'provider.example',
      },
      allowPause: true,
      retries: 2,
      parallelChunks: 1,
    );

    await f.manager.start(f.request);

    await expectLater(
      f.manager.start(conflicting),
      throwsStateError,
    );

    expect(f.gateway.startedSpecs, hasLength(1));
    expect(f.resolver.calls, 1);
  });

  test('resume refuses duplicate paused owners of one canonical destination', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _FakeGateway();
    final resolver = StaticSourceResolverV2();
    const destination = 'downloads/anime/shared-episode.mp4';

    final firstId = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );
    final secondId = logicalDownloadIdFor(
      animeId: 'anilist:22',
      episodeKey: '13',
      variantKey: 'sub:1080p',
    );
    final firstTaskId = taskIdForGeneration(firstId, 1);
    final secondTaskId = taskIdForGeneration(secondId, 1);

    for (final record in <LogicalDownloadRecordV2>[
      LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: firstId,
        animeId: 'anilist:21',
        episodeKey: '12',
        variantKey: 'sub:1080p',
        generation: 1,
        taskId: firstTaskId,
        intent: DownloadUserIntent.paused,
        destinationPath: destination,
        sourceDescriptor: const <String, Object?>{
          'providerId': 'provider.example',
        },
        allowPause: true,
        retries: 2,
        parallelChunks: 1,
        updatedAtMillis: 1,
      ),
      LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: secondId,
        animeId: 'anilist:22',
        episodeKey: '13',
        variantKey: 'sub:1080p',
        generation: 1,
        taskId: secondTaskId,
        intent: DownloadUserIntent.paused,
        destinationPath: destination,
        sourceDescriptor: const <String, Object?>{
          'providerId': 'provider.example',
        },
        allowPause: true,
        retries: 2,
        parallelChunks: 1,
        updatedAtMillis: 2,
      ),
    ]) {
      await store.put(record);
      await gateway.start(
        DownloadTaskSpecV2(
          taskId: record.taskId,
          url: 'https://example.invalid/video.mp4',
          destinationPath: destination,
          headers: const <String, String>{},
          allowPause: true,
          retries: 2,
          parallelChunks: 1,
        ),
      );
      gateway.emit(record.taskId, DownloadTransportStatus.paused);
    }

    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    addTearDown(manager.dispose);
    await manager.initialize();

    await expectLater(manager.resume(firstId), throwsStateError);

    expect(gateway.handleFor(firstTaskId)!.resumeCalls, 0);
    expect(gateway.handleFor(secondTaskId)!.resumeCalls, 0);
    expect((await store.get(firstId))?.intent, DownloadUserIntent.paused);
    expect((await store.get(secondId))?.intent, DownloadUserIntent.paused);
  });

  test('resumable paused handle becomes durably active without replacement', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;

    await f.manager.pause(f.request.logicalId);
    f.gateway.emit(taskId, DownloadTransportStatus.paused);

    await f.manager.resume(f.request.logicalId);

    expect(handle.resumeCalls, 1);
    expect(f.gateway.startedSpecs, hasLength(1));
    expect(f.resolver.calls, 1);
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.active,
    );
    expect(
      f.manager.snapshotFor(f.request.logicalId)?.taskId,
      taskId,
    );
  });

  test('failed exact resume keeps paused generation without replacement', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final firstTaskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(firstTaskId)!;

    await f.manager.pause(f.request.logicalId);
    f.gateway.emit(firstTaskId, DownloadTransportStatus.paused);
    handle.onResume = () async => false;

    await expectLater(
      f.manager.resume(f.request.logicalId),
      throwsStateError,
    );

    expect(handle.resumeCalls, 1);
    expect(handle.cancelCalls, 0);
    expect(f.gateway.startedSpecs, hasLength(1));
    expect((await f.store.get(f.request.logicalId))?.generation, 1);
    expect((await f.store.get(f.request.logicalId))?.taskId, firstTaskId);
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.paused,
    );
  });
  test('canceled exact handle after resume failure cannot restart generation', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;

    await f.manager.pause(f.request.logicalId);
    f.gateway.emit(taskId, DownloadTransportStatus.paused);
    handle.onResume = () async => false;

    await expectLater(f.manager.resume(f.request.logicalId), throwsStateError);
    f.gateway.emit(taskId, DownloadTransportStatus.canceled);
    await Future<void>.delayed(Duration.zero);

    await expectLater(f.manager.resume(f.request.logicalId), throwsStateError);

    expect(f.gateway.startedSpecs, hasLength(1));
    expect((await f.store.get(f.request.logicalId))?.generation, 1);
    expect((await f.store.get(f.request.logicalId))?.taskId, taskId);
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.paused,
    );
  });

  test('pause fallback waits for cancellation settlement', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;
    handle.onPause = () async => false;
    handle.onCancel = () async => true;

    var completed = false;
    final pauseFuture = f.manager.pause(f.request.logicalId).whenComplete(() {
      completed = true;
    });
    await Future<void>.delayed(Duration.zero);

    expect(handle.cancelCalls, 1);
    expect(completed, isFalse);

    f.gateway.emit(taskId, DownloadTransportStatus.canceled);
    final snapshot = await pauseFuture;

    expect(completed, isTrue);
    expect(snapshot?.status, DownloadTransportStatus.paused);
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.paused,
    );
  });

  test('non-resumable pause cancels transport but retains paused intent', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final handle = f.gateway.handleFor(f.gateway.startedSpecs.single.taskId)!;
    handle.onPause = () async => false;

    await f.manager.pause(f.request.logicalId);

    expect(handle.cancelCalls, 1);
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.paused,
    );
  });

  test('missing current transport resumes with a fresh generation', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final firstTaskId = f.gateway.startedSpecs.single.taskId;
    await f.manager.pause(f.request.logicalId);
    f.gateway.emit(firstTaskId, DownloadTransportStatus.missing);

    await f.manager.resume(f.request.logicalId);

    expect(f.gateway.startedSpecs, hasLength(2));
    expect(f.gateway.startedSpecs.last.taskId, isNot(firstTaskId));
    expect(f.resolver.calls, 2);
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.active,
    );
  });

  test('cancel waits for obsolete writer settlement before releasing tracking', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;
    handle.onCancel = () async => true;

    var completed = false;
    final cancelFuture = f.manager.cancel(f.request.logicalId).whenComplete(() {
      completed = true;
    });
    await Future<void>.delayed(Duration.zero);

    expect(handle.cancelCalls, 1);
    expect(completed, isFalse);
    expect(f.gateway.removedTracking, isNot(contains(taskId)));

    f.gateway.emit(taskId, DownloadTransportStatus.canceled);
    await cancelFuture;

    expect(completed, isTrue);
    expect(f.gateway.removedTracking, contains(taskId));
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.canceled,
    );
  });

  test('cancel fences old generation before late callback', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final oldTaskId = f.gateway.startedSpecs.single.taskId;

    await f.manager.cancel(f.request.logicalId);
    final canceledRecord = await f.store.get(f.request.logicalId);
    expect(canceledRecord, isNotNull);
    expect(canceledRecord!.intent, DownloadUserIntent.canceled);
    expect(canceledRecord.taskId, isNot(oldTaskId));

    f.gateway.emit(oldTaskId, DownloadTransportStatus.complete);
    await Future<void>.delayed(Duration.zero);

    expect(
      f.manager.snapshotFor(f.request.logicalId)?.taskId,
      canceledRecord.taskId,
    );
    expect(
      f.manager.snapshotFor(f.request.logicalId)?.status,
      DownloadTransportStatus.canceled,
    );
  });

  test('delete is idempotent when destination is already missing', () async {
    final temp = await Directory.systemTemp.createTemp('animewitcher-v2-delete-');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final destination = File('${temp.path}${Platform.pathSeparator}episode.mp4');
    await destination.writeAsBytes(<int>[1, 2, 3]);
    final f = _fixture(destinationPath: destination.path);
    await f.manager.start(f.request);

    await f.manager.delete(f.request.logicalId);
    await f.manager.delete(f.request.logicalId);

    expect(await destination.exists(), isFalse);
    expect(await f.store.get(f.request.logicalId), isNull);
  });
}

_Fixture _fixture({
  String destinationPath = 'downloads/anime/episode-12.mp4',
  int parallelChunks = 1,
}) {
  final store = InMemoryLogicalDownloadStoreV2();
  final gateway = _FakeGateway();
  final resolver = StaticSourceResolverV2();
  final logicalId = logicalDownloadIdFor(
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
  );
  final request = DownloadStartRequestV2(
    logicalId: logicalId,
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
    destinationPath: destinationPath,
    sourceDescriptor: const <String, Object?>{
      'providerId': 'provider.example',
    },
    allowPause: true,
    retries: 2,
    parallelChunks: parallelChunks,
  );
  return _Fixture(
    store: store,
    gateway: gateway,
    resolver: resolver,
    request: request,
    manager: DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    ),
  );
}

final class _Fixture {
  const _Fixture({
    required this.store,
    required this.gateway,
    required this.resolver,
    required this.request,
    required this.manager,
  });

  final InMemoryLogicalDownloadStoreV2 store;
  final _FakeGateway gateway;
  final StaticSourceResolverV2 resolver;
  final DownloadStartRequestV2 request;
  final DownloadManagerV2 manager;
}

final class _FakeGateway implements BackgroundDownloaderGateway {
  final List<DownloadTaskSpecV2> startedSpecs = <DownloadTaskSpecV2>[];
  final List<String> removedTracking = <String>[];
  final Map<String, _FakeHandle> _handles = <String, _FakeHandle>{};

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    startedSpecs.add(spec);
    final handle = _FakeHandle(
      DownloadTransportSnapshot(
        taskId: spec.taskId,
        status: DownloadTransportStatus.running,
        progress: 0,
      ),
    );
    _handles[spec.taskId] = handle;
    return handle;
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async =>
      _handles[taskId];

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      _handles.values.toList(growable: false);

  @override
  Future<void> removeTracking(String taskId) async {
    removedTracking.add(taskId);
  }

  _FakeHandle? handleFor(String taskId) => _handles[taskId];

  void emit(String taskId, DownloadTransportStatus status) {
    _handles[taskId]?.emit(status);
  }

  void emitSnapshot(String taskId, DownloadTransportSnapshot snapshot) {
    _handles[taskId]?.emitSnapshot(snapshot);
  }
}

final class _FakeHandle implements DownloadTransportHandle {
  _FakeHandle(this._current);

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);

  Future<bool> Function()? onPause;
  Future<bool> Function()? onResume;
  Future<bool> Function()? onCancel;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int cancelCalls = 0;

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
    emit(DownloadTransportStatus.paused);
    return true;
  }

  @override
  Future<bool> resume() async {
    resumeCalls++;
    return onResume?.call() ?? true;
  }

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    final override = onCancel;
    if (override != null) return override();
    emit(DownloadTransportStatus.canceled);
    return true;
  }

  void emit(DownloadTransportStatus status) {
    emitSnapshot(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: status,
        progress: status == DownloadTransportStatus.complete ? 1 : 0.5,
      ),
    );
  }

  void emitSnapshot(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    _controller.add(_current);
  }
}


final class _RecordingPresentationObserver
    implements DownloadPresentationObserverV2 {
  final List<(LogicalDownloadRecordV2, DownloadTransportSnapshot)> events =
      <(LogicalDownloadRecordV2, DownloadTransportSnapshot)>[];

  @override
  Future<void> observe(
    LogicalDownloadRecordV2 record,
    DownloadTransportSnapshot snapshot,
  ) async {
    events.add((record, snapshot));
  }

  @override
  Future<void> dispose() async {}
}
