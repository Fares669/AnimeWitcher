import 'dart:async';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

const _source = ResolvedDownloadSourceV2(
  url: 'https://cdn.example.invalid/episode.mp4',
  headers: <String, String>{},
  expectedBytes: 100,
);

void main() {
  test(
    'a queued resume whose transfer throws stays paused, not failed',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _FakeGateway();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: _FakeResolver(),
        maxConcurrentDownloads: () => 1,
      );
      addTearDown(manager.dispose);
      final paused = _request('1');
      final other = _request('2');

      await manager.start(paused);
      await manager.pause(paused.logicalId);
      await manager.start(other);
      // No free slot: the resume waits in the queue with its paused transfer.
      await manager.resume(paused.logicalId);
      expect((await store.get(paused.logicalId))?.awaitingAdmission, isTrue);

      gateway.handleFor(gateway.taskIdOf(paused))!.throwOnResume = true;
      await manager.cancel(other.logicalId);
      await _until(
        () async =>
            (await store.get(paused.logicalId))?.awaitingAdmission == false,
      );

      final record = await store.get(paused.logicalId);
      expect(record?.intent, DownloadUserIntent.paused);
      expect(gateway.handleFor(gateway.taskIdOf(paused))!.cancelCalls, 0);
    },
  );

  test(
    'recovery that fails at launch leaves the download to resume next time',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final request = _request('1');
      final first = DownloadManagerV2(
        store: store,
        gateway: _FakeGateway(),
        sourceResolver: _FakeResolver(),
      );
      await first.start(request);
      await first.dispose();

      // Relaunched offline, with the system's transfer gone.
      final offline = DownloadManagerV2(
        store: store,
        gateway: _FakeGateway(),
        sourceResolver: _FakeResolver(fail: true),
      );
      await offline.initialize();
      expect(
        offline.snapshotFor(request.logicalId)?.status,
        DownloadTransportStatus.failed,
      );
      expect(
        (await store.get(request.logicalId))?.intent,
        DownloadUserIntent.active,
      );
      await offline.dispose();

      final online = _FakeGateway();
      final relaunched = DownloadManagerV2(
        store: store,
        gateway: online,
        sourceResolver: _FakeResolver(),
      );
      addTearDown(relaunched.dispose);
      await relaunched.initialize();
      expect(online.startedSpecs, hasLength(1));
    },
  );

  test('renewals that deliver bytes do not use up the renewal limit', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _FakeGateway();
    final resolver = _FakeResolver();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    addTearDown(manager.dispose);
    final request = _request('1');
    await manager.start(request);

    // A long download whose link expires five times, each renewed link
    // delivering bytes before it expires in turn.
    for (var renewal = 1; renewal <= 5; renewal++) {
      gateway.emitSourceExpired(gateway.startedSpecs.last.taskId);
      await gateway.waitForStarts(renewal + 1);
      // Let the manager subscribe to the renewed transfer first.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gateway.emitProgress(gateway.startedSpecs.last.taskId, 0.1 * renewal);
    }

    expect(resolver.calls, 6);
    expect(
      (await store.get(request.logicalId))?.intent,
      DownloadUserIntent.active,
    );
  });

  test('a renewal that cannot resolve is saved as an expired source', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _FakeGateway();
    final resolver = _FakeResolver();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    addTearDown(manager.dispose);
    final request = _request('1');
    await manager.start(request);

    resolver.fail = true;
    gateway.emitSourceExpired(gateway.startedSpecs.last.taskId);
    await _until(
      () async =>
          (await store.get(request.logicalId))?.intent ==
          DownloadUserIntent.failed,
    );

    expect(
      (await store.get(request.logicalId))?.failureCategory,
      DownloadFailureCategory.sourceExpired,
    );
  });

  test(
    'downloading a paused episode whose transfer is gone starts it again',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final request = _request('1');
      final first = DownloadManagerV2(
        store: store,
        gateway: _FakeGateway(),
        sourceResolver: _FakeResolver(),
      );
      await first.start(request);
      await first.pause(request.logicalId);
      await first.dispose();

      // The system dropped the paused transfer.
      final gateway = _FakeGateway();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: _FakeResolver(),
      );
      addTearDown(manager.dispose);
      await manager.start(request);

      expect(gateway.startedSpecs, hasLength(1));
      expect(
        (await store.get(request.logicalId))?.intent,
        DownloadUserIntent.active,
      );
    },
  );
}

Future<void> _until(Future<bool> Function() done) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not reached');
}

DownloadStartRequestV2 _request(String episode) {
  final logicalId = logicalDownloadIdFor(
    animeId: 'anilist:21',
    episodeKey: episode,
    variantKey: 'sub:1080p',
  );
  return DownloadStartRequestV2(
    logicalId: logicalId,
    mediaId: 'anilist:21',
    unitKey: episode,
    variantKey: 'sub:1080p',
    destinationPath: 'downloads/anime/episode-$episode.mp4',
    sourceDescriptor: <String, Object?>{
      'providerId': 'provider.example',
      'trackingUrl': '/anime/21/$episode',
    },
    allowPause: true,
    retries: 2,
    parallelChunks: 1,
  );
}

final class _FakeResolver implements DownloadSourceResolverV2 {
  _FakeResolver({this.fail = false});

  bool fail;
  int calls = 0;

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    calls++;
    if (fail) throw StateError('offline');
    return _source;
  }
}

final class _FakeGateway implements BackgroundDownloaderGateway {
  final List<DownloadTaskSpecV2> startedSpecs = <DownloadTaskSpecV2>[];
  final Map<String, _FakeHandle> _handles = <String, _FakeHandle>{};
  final List<Completer<void>> _startWaiters = <Completer<void>>[];

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
    for (final waiter in List<Completer<void>>.from(_startWaiters)) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _startWaiters.clear();
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

  _FakeHandle? handleFor(String taskId) => _handles[taskId];

  String taskIdOf(DownloadStartRequestV2 request) => startedSpecs
      .lastWhere((spec) => spec.taskId.contains(request.logicalId.value))
      .taskId;

  void emitSourceExpired(String taskId) {
    _handles[taskId]?.emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.failed,
        progress: 0,
        failureCategory: DownloadFailureCategory.sourceExpired,
        failureMessage: 'HTTP 403',
      ),
    );
  }

  void emitProgress(String taskId, double progress) {
    _handles[taskId]?.emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: progress,
      ),
    );
  }

  Future<void> waitForStarts(int count) async {
    while (startedSpecs.length < count) {
      final waiter = Completer<void>();
      _startWaiters.add(waiter);
      await waiter.future.timeout(const Duration(seconds: 3));
    }
  }
}

final class _FakeHandle implements DownloadTransportHandle {
  _FakeHandle(this._current);

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);
  int cancelCalls = 0;
  bool throwOnResume = false;

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  @override
  Future<bool> pause() async {
    emit(_with(DownloadTransportStatus.paused));
    return true;
  }

  @override
  Future<bool> resume() async {
    if (throwOnResume) throw StateError('native resume rejected');
    emit(_with(DownloadTransportStatus.running));
    return true;
  }

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    emit(_with(DownloadTransportStatus.canceled));
    return true;
  }

  DownloadTransportSnapshot _with(DownloadTransportStatus status) =>
      DownloadTransportSnapshot(
        taskId: _current.taskId,
        status: status,
        progress: _current.progress,
      );

  void emit(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    _controller.add(snapshot);
  }
}
