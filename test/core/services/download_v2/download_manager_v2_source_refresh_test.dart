import 'dart:async';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'duplicate expiration callbacks do not consume future renewal budget',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _FakeGateway();
      final resolver = _FakeResolver(
        List.filled(
          5,
          const ResolvedDownloadSourceV2(
            url: 'https://cdn.example.invalid/renewed.mp4',
            headers: <String, String>{},
            expectedBytes: 100,
          ),
        ),
      );
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
      );
      addTearDown(manager.dispose);
      final request = _request();
      await manager.start(request);
      for (var renewal = 0; renewal < 3; renewal++) {
        final taskId = gateway.startedSpecs.last.taskId;
        for (var duplicate = 0; duplicate < 5; duplicate++) {
          gateway.emitSourceExpired(taskId);
        }
        await gateway.waitForStarts(renewal + 2);
        await Future<void>.delayed(Duration.zero);
        expect(
          (await store.get(request.logicalId))?.intent,
          DownloadUserIntent.active,
        );
      }
      gateway.emitSourceExpired(gateway.startedSpecs.last.taskId);
      for (var attempt = 0; attempt < 100; attempt++) {
        if ((await store.get(request.logicalId))?.intent ==
            DownloadUserIntent.failed)
          break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(resolver.calls, 4);
      expect(
        (await store.get(request.logicalId))?.intent,
        DownloadUserIntent.failed,
      );

      await manager.restart(request.logicalId);
      expect(resolver.calls, 5);
      expect(
        (await store.get(request.logicalId))?.intent,
        DownloadUserIntent.active,
      );
    },
  );

  test(
    'current-generation 403 resolves one fresh source and replaces task',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _FakeGateway();
      final resolver = _FakeResolver(<ResolvedDownloadSourceV2>[
        const ResolvedDownloadSourceV2(
          url: 'https://cdn.example.invalid/first.mp4?token=old',
          headers: <String, String>{'authorization': 'old'},
          expectedBytes: 100,
        ),
        const ResolvedDownloadSourceV2(
          url: 'https://cdn.example.invalid/second.mp4?token=new',
          headers: <String, String>{'authorization': 'new'},
          expectedBytes: 100,
        ),
      ]);
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
      );
      final request = _request();

      await manager.start(request);
      final oldTaskId = gateway.startedSpecs.single.taskId;
      expect(resolver.calls, 1);

      gateway.emitSourceExpired(oldTaskId);
      gateway.emitSourceExpired(oldTaskId);
      await gateway.waitForStarts(2);

      expect(resolver.calls, 2);
      expect(gateway.startedSpecs, hasLength(2));
      expect(gateway.startedSpecs.first.url, contains('token=old'));
      expect(gateway.startedSpecs.last.url, contains('token=new'));
      expect(gateway.startedSpecs.last.taskId, isNot(oldTaskId));
      expect(gateway.handleFor(oldTaskId)?.cancelCalls, 1);

      final current = await store.get(request.logicalId);
      expect(current, isNotNull);
      expect(current!.taskId, gateway.startedSpecs.last.taskId);
      expect(current.generation, 2);
      expect(current.expectedBytes, 100);
    },
  );

  test('pause interrupts a stalled in-place source resolver', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _RenewingFakeGateway();
    final resolver = _BlockingRenewalResolver();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    addTearDown(() async {
      resolver.release();
      await manager.dispose();
    });
    final request = _request();

    await manager.start(request);
    final handle = gateway.handle!;
    handle.emitSourceExpired();
    await resolver.renewalEntered.future.timeout(const Duration(seconds: 2));

    final paused = await manager
        .pause(request.logicalId)
        .timeout(const Duration(seconds: 2));

    expect(paused?.status, DownloadTransportStatus.paused);
    expect(handle.replaceSourceCalls, 0);
    expect(resolver.renewalReleased, isFalse);
    expect((await store.get(request.logicalId))?.generation, 1);
    expect(
      (await store.get(request.logicalId))?.intent,
      DownloadUserIntent.paused,
    );
  });

  test(
    'pause during non-renewable refresh preserves generation and paused intent',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _FakeGateway();
      final resolver = _BlockingRenewalResolver();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
      );
      addTearDown(() async {
        resolver.release();
        await manager.dispose();
      });
      final request = _request();

      await manager.start(request);
      final original = (await store.get(request.logicalId))!;
      gateway.emitSourceExpired(original.taskId);
      await resolver.renewalEntered.future.timeout(const Duration(seconds: 2));

      await manager
          .pause(request.logicalId)
          .timeout(const Duration(seconds: 2));

      final paused = (await store.get(request.logicalId))!;
      expect(paused.intent, DownloadUserIntent.paused);
      expect(paused.generation, original.generation);
      expect(paused.taskId, original.taskId);
      expect(gateway.startedSpecs, hasLength(1));
    },
  );

  test(
    'user-stopped renewals do not consume the source refresh budget',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _RenewingFakeGateway();
      final resolver = _RepeatBlockingRenewalResolver();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
      );
      addTearDown(() async {
        resolver.releaseAll();
        await manager.dispose();
      });
      final request = _request();

      await manager.start(request);
      for (var cycle = 0; cycle < 3; cycle++) {
        gateway.handle!.emitSourceExpired();
        await resolver.waitForCalls(cycle + 2);
        await manager
            .pause(request.logicalId)
            .timeout(const Duration(seconds: 2));
        expect(
          (await store.get(request.logicalId))?.intent,
          DownloadUserIntent.paused,
        );
        await manager
            .resume(request.logicalId)
            .timeout(const Duration(seconds: 2));
        expect(
          (await store.get(request.logicalId))?.intent,
          DownloadUserIntent.active,
        );
      }

      gateway.handle!.emitSourceExpired();
      for (var attempt = 0; attempt < 100; attempt++) {
        if (resolver.calls >= 5 ||
            (await store.get(request.logicalId))?.intent ==
                DownloadUserIntent.failed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(
        resolver.calls,
        5,
        reason: 'The fourth renewal must still be attempted',
      );
      expect(
        (await store.get(request.logicalId))?.intent,
        DownloadUserIntent.active,
      );
    },
  );

  test(
    'retry keeps ranged source-renewal failure on the same generation',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _RenewingFakeGateway(replaceResults: <bool>[false, true]);
      final resolver = _FakeResolver(<ResolvedDownloadSourceV2>[
        const ResolvedDownloadSourceV2(
          url: 'https://cdn.example.invalid/initial.mp4',
          headers: <String, String>{},
          expectedBytes: 100,
        ),
        const ResolvedDownloadSourceV2(
          url: 'https://cdn.example.invalid/rejected.mp4',
          headers: <String, String>{},
          expectedBytes: 100,
        ),
        const ResolvedDownloadSourceV2(
          url: 'https://cdn.example.invalid/retry.mp4',
          headers: <String, String>{},
          expectedBytes: 100,
        ),
      ]);
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
      );
      addTearDown(manager.dispose);
      final request = _request();

      await manager.start(request);
      final original = (await store.get(request.logicalId))!;
      gateway.handle!.emitSourceExpired();
      for (var attempt = 0; attempt < 100; attempt++) {
        if ((await store.get(request.logicalId))?.intent ==
            DownloadUserIntent.failed) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final failed = (await store.get(request.logicalId))!;
      expect(failed.intent, DownloadUserIntent.failed);
      expect(failed.failureCategory, DownloadFailureCategory.sourceExpired);
      expect(failed.generation, original.generation);
      expect(gateway.handle!.replaceSourceCalls, 1);

      await manager.retry(request.logicalId);
      for (var attempt = 0; attempt < 100; attempt++) {
        final current = await store.get(request.logicalId);
        if (gateway.handle!.replaceSourceCalls == 2 &&
            current?.intent == DownloadUserIntent.active &&
            gateway.handle!.current.status == DownloadTransportStatus.running) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final retried = (await store.get(request.logicalId))!;
      expect(retried.generation, original.generation);
      expect(retried.taskId, original.taskId);
      expect(retried.intent, DownloadUserIntent.active);
      expect(retried.failureCategory, isNull);
      expect(gateway.starts, 1);
      expect(gateway.handle!.replaceSourceCalls, 2);
      expect(gateway.handle!.current.status, DownloadTransportStatus.running);
    },
  );

  for (final paused in <bool>[false, true]) {
    test(
      'retry ignores a ${paused ? 'paused' : 'active'} logical download',
      () async {
        final store = InMemoryLogicalDownloadStoreV2();
        final gateway = _FakeGateway();
        final resolver = _FakeResolver(<ResolvedDownloadSourceV2>[
          const ResolvedDownloadSourceV2(
            url: 'https://cdn.example.invalid/initial.mp4',
            headers: <String, String>{},
            expectedBytes: 100,
          ),
          const ResolvedDownloadSourceV2(
            url: 'https://cdn.example.invalid/unexpected-retry.mp4',
            headers: <String, String>{},
            expectedBytes: 100,
          ),
        ]);
        final manager = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: resolver,
        );
        addTearDown(manager.dispose);
        final request = _request();

        await manager.start(request);
        if (paused) await manager.pause(request.logicalId);
        final before = (await store.get(request.logicalId))!;

        final snapshot = await manager.retry(request.logicalId);
        final after = (await store.get(request.logicalId))!;

        expect(snapshot.taskId, before.taskId);
        expect(after.taskId, before.taskId);
        expect(after.generation, before.generation);
        expect(after.intent, before.intent);
        expect(gateway.startedSpecs, hasLength(1));
        expect(resolver.calls, 1);
      },
    );
  }
}

DownloadStartRequestV2 _request() {
  final logicalId = logicalDownloadIdFor(
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
  );
  return DownloadStartRequestV2(
    logicalId: logicalId,
    mediaId: 'anilist:21',
    unitKey: '12',
    variantKey: 'sub:1080p',
    destinationPath: 'downloads/anime/episode-12.mp4',
    sourceDescriptor: const <String, Object?>{
      'providerId': 'provider.example',
      'trackingUrl': '/anime/21/12',
    },
    allowPause: true,
    retries: 2,
    parallelChunks: 1,
  );
}

final class _FakeResolver implements DownloadSourceResolverV2 {
  _FakeResolver(this._sources);

  final List<ResolvedDownloadSourceV2> _sources;
  int calls = 0;

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    final index = calls++;
    return _sources[index];
  }
}

final class _BlockingRenewalResolver implements DownloadSourceResolverV2 {
  final renewalEntered = Completer<void>();
  final _renewalRelease = Completer<void>();
  var calls = 0;

  bool get renewalReleased => _renewalRelease.isCompleted;

  void release() {
    if (!_renewalRelease.isCompleted) _renewalRelease.complete();
  }

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    calls++;
    if (calls == 1) {
      return const ResolvedDownloadSourceV2(
        url: 'https://cdn.example.invalid/initial.mp4',
        headers: <String, String>{},
        expectedBytes: 100,
      );
    }
    if (!renewalEntered.isCompleted) renewalEntered.complete();
    await _renewalRelease.future;
    return const ResolvedDownloadSourceV2(
      url: 'https://cdn.example.invalid/renewed.mp4',
      headers: <String, String>{},
      expectedBytes: 100,
    );
  }
}

final class _RepeatBlockingRenewalResolver implements DownloadSourceResolverV2 {
  final List<Completer<ResolvedDownloadSourceV2>> _blocked =
      <Completer<ResolvedDownloadSourceV2>>[];
  var calls = 0;

  Future<void> waitForCalls(int expected) async {
    for (var attempt = 0; attempt < 100 && calls < expected; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (calls < expected) {
      throw TimeoutException('Expected $expected resolver calls, got $calls');
    }
  }

  void releaseAll() {
    for (final blocked in _blocked) {
      if (!blocked.isCompleted) {
        blocked.complete(
          const ResolvedDownloadSourceV2(
            url: 'https://cdn.example.invalid/released.mp4',
            headers: <String, String>{},
            expectedBytes: 100,
          ),
        );
      }
    }
  }

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    calls++;
    if (calls == 1) {
      return const ResolvedDownloadSourceV2(
        url: 'https://cdn.example.invalid/initial.mp4',
        headers: <String, String>{},
        expectedBytes: 100,
      );
    }
    final blocked = Completer<ResolvedDownloadSourceV2>();
    _blocked.add(blocked);
    return blocked.future;
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

  void emitSourceExpired(String taskId) {
    _handles[taskId]?.emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.failed,
        progress: 0.5,
        failureCategory: DownloadFailureCategory.sourceExpired,
        failureMessage: 'HTTP 403',
      ),
    );
  }

  Future<void> waitForStarts(int count) async {
    while (startedSpecs.length < count) {
      final waiter = Completer<void>();
      _startWaiters.add(waiter);
      await waiter.future.timeout(const Duration(seconds: 2));
    }
  }
}

final class _FakeHandle implements DownloadTransportHandle {
  _FakeHandle(this._current);

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);
  int cancelCalls = 0;

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  @override
  Future<bool> pause() async {
    emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.paused,
        progress: _current.progress,
        totalBytes: _current.totalBytes,
      ),
    );
    return true;
  }

  @override
  Future<bool> resume() async {
    emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: _current.progress,
        totalBytes: _current.totalBytes,
      ),
    );
    return true;
  }

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.canceled,
        progress: _current.progress,
        totalBytes: _current.totalBytes,
      ),
    );
    return true;
  }

  void emit(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    _controller.add(snapshot);
  }
}

final class _RenewingFakeGateway implements BackgroundDownloaderGateway {
  _RenewingFakeGateway({List<bool> replaceResults = const <bool>[]})
    : _replaceResults = List<bool>.from(replaceResults);

  final List<bool> _replaceResults;
  _RenewingFakeHandle? handle;
  var starts = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    starts++;
    return handle = _RenewingFakeHandle(
      DownloadTransportSnapshot(
        taskId: spec.taskId,
        status: DownloadTransportStatus.running,
        progress: 0.5,
        totalBytes: spec.expectedBytes,
      ),
      replaceResults: _replaceResults,
    );
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async =>
      handle?.taskId == taskId ? handle : null;

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      handle == null ? const [] : <DownloadTransportHandle>[handle!];

  @override
  Future<void> removeTracking(String taskId) async {}
}

final class _RenewingFakeHandle
    implements
        DownloadTransportHandle,
        SourceRenewingDownloadTransportHandleV2 {
  _RenewingFakeHandle(
    this._current, {
    List<bool> replaceResults = const <bool>[],
  }) : _replaceResults = List<bool>.from(replaceResults);

  DownloadTransportSnapshot _current;
  final List<bool> _replaceResults;
  final _controller = StreamController<DownloadTransportSnapshot>.broadcast(
    sync: true,
  );
  var replaceSourceCalls = 0;

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  void emitSourceExpired() {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.failed,
      progress: 0.5,
      totalBytes: _current.totalBytes,
      failureCategory: DownloadFailureCategory.sourceExpired,
      failureMessage: 'HTTP 403',
    );
    _controller.add(_current);
  }

  @override
  void interruptSourceRenewal() {}

  @override
  Future<bool> replaceSource({
    required String url,
    required Map<String, String> headers,
    int? expectedBytes,
  }) async {
    replaceSourceCalls++;
    final accepted = _replaceResults.isEmpty
        ? true
        : _replaceResults.removeAt(0);
    if (!accepted) return false;
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.paused,
      progress: 0.5,
      totalBytes: expectedBytes ?? _current.totalBytes,
    );
    _controller.add(_current);
    return true;
  }

  @override
  Future<bool> pause() async {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.paused,
      progress: 0.5,
      totalBytes: _current.totalBytes,
    );
    _controller.add(_current);
    return true;
  }

  @override
  Future<bool> resume() async {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.running,
      progress: 0.5,
      totalBytes: _current.totalBytes,
    );
    _controller.add(_current);
    return true;
  }

  @override
  Future<bool> cancel() async => true;
}
