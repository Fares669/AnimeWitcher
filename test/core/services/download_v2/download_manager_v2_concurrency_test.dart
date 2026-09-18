import 'dart:async';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('logical concurrency caps episodes without counting package chunks', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _ConcurrencyGateway();
    final resolver = _Resolver();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
      maxConcurrentDownloads: () => 1,
    );
    addTearDown(manager.dispose);

    final first = _request(episode: '1', chunks: 16);
    final second = _request(episode: '2', chunks: 16);

    final firstSnapshot = await manager.start(first);
    expect(firstSnapshot.status, DownloadTransportStatus.running);
    expect(gateway.startedSpecs, hasLength(1));
    expect(gateway.startedSpecs.single.parallelChunks, 16);
    expect(resolver.calls, 1);

    final secondSnapshot = await manager.start(second);
    expect(secondSnapshot.status, DownloadTransportStatus.queued);
    expect(gateway.startedSpecs, hasLength(1));
    expect(resolver.calls, 1);

    final queuedRecord = await store.get(second.logicalId);
    expect(queuedRecord, isNotNull);
    expect(queuedRecord!.awaitingAdmission, isTrue);
    expect(queuedRecord.intent, DownloadUserIntent.active);

    gateway.emit(
      gateway.startedSpecs.first.taskId,
      DownloadTransportStatus.failed,
    );
    await gateway.waitForStarts(2);

    expect(resolver.calls, 2);
    expect(gateway.startedSpecs, hasLength(2));
    expect(gateway.startedSpecs.last.parallelChunks, 16);
    expect(gateway.startedSpecs.last.taskId, queuedRecord.taskId);
    expect((await store.get(second.logicalId))?.awaitingAdmission, isFalse);
  });

  test('resume waits for an episode slot and keeps the exact paused handle', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _ConcurrencyGateway();
    final resolver = _Resolver();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
      maxConcurrentDownloads: () => 1,
    );
    addTearDown(manager.dispose);

    final first = _request(episode: '1', chunks: 4);
    final second = _request(episode: '2', chunks: 4);

    await manager.start(first);
    final firstTaskId = gateway.startedSpecs.single.taskId;
    final firstHandle = gateway.handleFor(firstTaskId)!;

    final pauseFuture = manager.pause(first.logicalId);
    await Future<void>.delayed(Duration.zero);
    gateway.emit(firstTaskId, DownloadTransportStatus.paused);
    await pauseFuture;

    await manager.start(second);
    final secondTaskId = gateway.startedSpecs.last.taskId;
    expect(gateway.startedSpecs, hasLength(2));

    final queuedResume = await manager.resume(first.logicalId);
    expect(queuedResume.status, DownloadTransportStatus.queued);
    expect(firstHandle.resumeCalls, 0);
    expect((await store.get(first.logicalId))?.taskId, firstTaskId);
    expect((await store.get(first.logicalId))?.generation, 1);
    expect((await store.get(first.logicalId))?.awaitingAdmission, isTrue);

    gateway.emit(secondTaskId, DownloadTransportStatus.failed);
    await firstHandle.waitForResume();

    expect(firstHandle.resumeCalls, 1);
    expect(gateway.startedSpecs, hasLength(2));
    expect((await store.get(first.logicalId))?.taskId, firstTaskId);
    expect((await store.get(first.logicalId))?.generation, 1);
    expect((await store.get(first.logicalId))?.awaitingAdmission, isFalse);
  });

}

DownloadStartRequestV2 _request({
  required String episode,
  required int chunks,
}) {
  final logicalId = logicalDownloadIdFor(
    animeId: 'anilist:21',
    episodeKey: episode,
    variantKey: 'sub:1080p',
  );
  return DownloadStartRequestV2(
    logicalId: logicalId,
    animeId: 'anilist:21',
    episodeKey: episode,
    variantKey: 'sub:1080p',
    destinationPath: 'downloads/anime/episode-$episode.mp4',
    sourceDescriptor: <String, Object?>{
      'providerId': 'provider.example',
      'episode': episode,
    },
    allowPause: true,
    retries: 2,
    parallelChunks: chunks,
  );
}

final class _Resolver implements DownloadSourceResolverV2 {
  int calls = 0;

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    calls++;
    return ResolvedDownloadSourceV2(
      url: 'https://example.invalid/${descriptor['episode']}.mp4',
      headers: const <String, String>{},
      expectedBytes: 100,
    );
  }
}

final class _ConcurrencyGateway implements BackgroundDownloaderGateway {
  final List<DownloadTaskSpecV2> startedSpecs = <DownloadTaskSpecV2>[];
  final Map<String, _ConcurrencyHandle> _handles =
      <String, _ConcurrencyHandle>{};
  final List<Completer<void>> _waiters = <Completer<void>>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    startedSpecs.add(spec);
    final handle = _ConcurrencyHandle(
      DownloadTransportSnapshot(
        taskId: spec.taskId,
        status: DownloadTransportStatus.running,
        progress: 0,
        totalBytes: 100,
        transferredBytes: 0,
      ),
    );
    _handles[spec.taskId] = handle;
    for (final waiter in List<Completer<void>>.from(_waiters)) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiters.clear();
    return handle;
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async =>
      _handles[taskId];

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      _handles.values.toList(growable: false);

  @override
  Future<void> removeTracking(String taskId) async {}

  _ConcurrencyHandle? handleFor(String taskId) => _handles[taskId];

  void emit(String taskId, DownloadTransportStatus status) {
    _handles[taskId]?.emit(status);
  }

  Future<void> waitForStarts(int count) async {
    while (startedSpecs.length < count) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future.timeout(const Duration(seconds: 2));
    }
  }
}

final class _ConcurrencyHandle implements DownloadTransportHandle {
  _ConcurrencyHandle(this._current);

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);
  final Completer<void> _resumeSignal = Completer<void>();
  int resumeCalls = 0;

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async {
    resumeCalls++;
    if (!_resumeSignal.isCompleted) _resumeSignal.complete();
    return true;
  }

  @override
  Future<bool> cancel() async => true;

  Future<void> waitForResume() =>
      _resumeSignal.future.timeout(const Duration(seconds: 2));

  void emit(DownloadTransportStatus status) {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: status,
      progress: status == DownloadTransportStatus.complete ? 1 : 0.5,
      totalBytes: 100,
      transferredBytes: status == DownloadTransportStatus.complete ? 100 : 50,
      failureCategory: status == DownloadTransportStatus.failed
          ? DownloadFailureCategory.transport
          : null,
    );
    _controller.add(_current);
  }
}
