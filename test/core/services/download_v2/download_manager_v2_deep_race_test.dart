import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

// Exercise the production coordinator. Only native/network transport is fake.
void main() {
  late _Fixture f;
  setUp(() async {
    f = await _Fixture.create();
  });
  tearDown(() async {
    await f.manager.dispose();
    await f.gateway.dispose();
    await f.root.delete(recursive: true);
  });

  test(
    'duplicate concurrent resume preserves the exact video writer',
    () async {
      final request = f.request('duplicate-resume');
      await f.manager.start(request);
      final original = f.gateway.handles.values.single;
      original.emit(DownloadTransportStatus.running, progress: .6);
      await f.manager.pause(request.logicalId);

      final results = await Future.wait([
        f.manager.resume(request.logicalId),
        f.manager.resume(request.logicalId),
        f.manager.resume(request.logicalId),
      ]);

      expect(
        f.gateway.started,
        hasLength(1),
        reason: 'repeated Resume must not cancel and redownload existing bytes',
      );
      expect(original.resumeCalls, 1);
      expect(original.cancelCalls, 0);
      expect(results.map((value) => value.taskId).toSet(), {original.taskId});
      expect(results.map((value) => value.progress), everyElement(.6));
      expect((await f.store.get(request.logicalId))?.generation, 1);
    },
  );

  for (final status in [
    DownloadTransportStatus.queued,
    DownloadTransportStatus.running,
    DownloadTransportStatus.held,
  ]) {
    test('resume of active video in $status does not restart it', () async {
      final request = f.request('active-$status');
      await f.manager.start(request);
      final original = f.gateway.handles.values.single;
      original.emit(status, progress: .45);
      final result = await f.manager.resume(request.logicalId);
      expect(result.taskId, original.taskId);
      expect(result.status, status);
      expect(result.progress, .45);
      expect(f.gateway.started, hasLength(1));
      expect(original.cancelCalls, 0);
      expect(original.resumeCalls, 0);
    });
  }

  test('renewable expired source keeps its generation and ignores duplicate expiry callbacks', () async {
    f.gateway.renewable = true;
    final request = f.request('renewable');
    await f.manager.start(request);
    final original = f.gateway.handles.values.single as _RenewableHandle;
    original.emit(DownloadTransportStatus.running, progress: .6);
    for (var i = 0; i < 5; i++) {
      original.emit(
        DownloadTransportStatus.failed,
        failureCategory: DownloadFailureCategory.sourceExpired,
      );
    }
    await _until(
      () => original.replaceCalls > 0 || f.gateway.started.length > 1,
    );
    await f.manager.reconcileAdmission();
    expect(original.replaceCalls, 1);
    expect(f.gateway.started, hasLength(1));
    expect(original.cancelCalls, 0);
    expect(original.resumeCalls, 1);
    expect(original.current.progress, .6);
    expect((await f.store.get(request.logicalId))?.generation, 1);
    expect(
      (await f.store.get(request.logicalId))?.intent,
      DownloadUserIntent.active,
    );
    expect(f.resolver.calls, 2);
  });

  test('renewed exact generation joins admission queue when another episode takes the slot', () async {
    f.limit = 1;
    f.gateway.renewable = true;
    final request = f.request('renewable-queue');
    await f.manager.start(request);
    final original = f.gateway.handles.values.single as _RenewableHandle;
    final resolveEntered = Completer<void>();
    final resolveRelease = Completer<void>();
    f.resolver.beforeResolve = (descriptor) async {
      if (descriptor['episode'] == request.unitKey) {
        resolveEntered.complete();
        await resolveRelease.future;
      }
    };
    original.emit(
      DownloadTransportStatus.failed,
      failureCategory: DownloadFailureCategory.sourceExpired,
    );
    await resolveEntered.future.timeout(const Duration(seconds: 3));
    try {
      await f.manager.start(f.request('other'));
    } finally {
      resolveRelease.complete();
    }
    await _until(
      () => original.replaceCalls > 0 || f.gateway.started.length > 2,
    );
    await f.manager.reconcileAdmission();
    expect(original.replaceCalls, 1);
    expect(original.resumeCalls, 0);
    expect(original.cancelCalls, 0);
    expect((await f.store.get(request.logicalId))?.generation, 1);
    expect((await f.store.get(request.logicalId))?.awaitingAdmission, isTrue);
    expect(
      f.manager.snapshotFor(request.logicalId)?.status,
      DownloadTransportStatus.queued,
    );
    await f.manager.cancel(f.request('other').logicalId);
    await f.manager.reconcileAdmission();
    expect(original.resumeCalls, 1);
    expect((await f.store.get(request.logicalId))?.awaitingAdmission, isFalse);
  });

  test('rejected in-place source validation never falls back to destructive restart', () async {
    f.gateway.renewable = true;
    final request = f.request('invalid-renewal');
    await f.manager.start(request);
    final original = f.gateway.handles.values.single as _RenewableHandle;
    original.replaceAccepted = false;
    original.emit(DownloadTransportStatus.running, progress: .7);
    original.emit(
      DownloadTransportStatus.failed,
      failureCategory: DownloadFailureCategory.sourceExpired,
    );
    await _until(
      () => original.replaceCalls > 0 || f.gateway.started.length > 1,
    );
    await _until(
      () =>
          (f.manager.snapshotFor(request.logicalId)?.failureMessage ?? '')
              .isNotEmpty ||
          f.gateway.started.length > 1,
    );
    expect(original.replaceCalls, 1);
    expect(original.cancelCalls, 0);
    expect(original.resumeCalls, 0);
    expect(f.gateway.started, hasLength(1));
    expect((await f.store.get(request.logicalId))?.generation, 1);
    expect(
      (await f.store.get(request.logicalId))?.intent,
      DownloadUserIntent.failed,
    );
    expect(
      (await f.store.get(request.logicalId))?.failureCategory,
      DownloadFailureCategory.sourceExpired,
    );
  });

  for (final control in ['pause', 'cancel', 'delete']) {
    test(
      '$control requested during renewal never restarts the paused native writer',
      () async {
        f.gateway.renewable = true;
        final request = f.request('stop-during-renewal-$control');
        await f.manager.start(request);
        final original = f.gateway.handles.values.single as _RenewableHandle;
        final resolveEntered = Completer<void>();
        final resolveRelease = Completer<void>();
        f.resolver.beforeResolve = (_) async {
          resolveEntered.complete();
          await resolveRelease.future;
        };
        original.emit(
          DownloadTransportStatus.failed,
          failureCategory: DownloadFailureCategory.sourceExpired,
        );
        await resolveEntered.future.timeout(const Duration(seconds: 3));
        final Future<Object?> stopped = switch (control) {
          'pause' => f.manager.pause(request.logicalId),
          'cancel' => f.manager.cancel(request.logicalId),
          _ => f.manager.delete(request.logicalId),
        };
        resolveRelease.complete();
        await stopped;
        expect(
          original.resumeCalls,
          0,
          reason: 'automatic recovery must yield to already requested user stop intent',
        );
        expect(f.gateway.started, hasLength(1));
        final record = await f.store.get(request.logicalId);
        if (control == 'delete') {
          expect(record, isNull);
        } else {
          expect(
            record?.intent,
            control == 'pause'
                ? DownloadUserIntent.paused
                : DownloadUserIntent.canceled,
          );
        }
      },
    );
  }

  test('checkpoint failure after native pause preserves paused user intent', () async {
    final request = f.request('paused-checkpoint-failure');
    await f.manager.start(request);
    final original = f.gateway.handles.values.single;
    original.pauseError = DownloadPauseCheckpointException(
      StateError('checkpoint unavailable'),
    );
    await expectLater(
      f.manager.pause(request.logicalId),
      throwsA(isA<DownloadPauseCheckpointException>()),
    );
    expect(
      (await f.store.get(request.logicalId))?.intent,
      DownloadUserIntent.paused,
    );
    expect(
      f.manager.snapshotFor(request.logicalId)?.status,
      DownloadTransportStatus.running,
      reason:
          'intent is durable but unsafe paused presentation must stay withheld',
    );
    expect(original.cancelCalls, 0);
  });

  test(
    'a rejected stop does not permanently suppress later source renewal',
    () async {
      f.gateway.renewable = true;
      final request = f.request('rejected-stop');
      await f.manager.start(request);
      final original = f.gateway.handles.values.single as _RenewableHandle;
      original.pauseError = StateError('native pause rejected');
      await expectLater(f.manager.pause(request.logicalId), throwsStateError);
      original.pauseError = null;
      original.emit(
        DownloadTransportStatus.failed,
        failureCategory: DownloadFailureCategory.sourceExpired,
      );
      await _until(() => original.resumeCalls == 1);
      expect(
        (await f.store.get(request.logicalId))?.intent,
        DownloadUserIntent.active,
      );
    },
  );

  test('same-ID source renewals retain bounded attempts despite stale progress samples', () async {
    f.gateway.renewable = true;
    final request = f.request('renewal-budget');
    await f.manager.start(request);
    final original = f.gateway.handles.values.single as _RenewableHandle;
    original.emit(DownloadTransportStatus.running, progress: .6);
    for (var renewal = 1; renewal <= 3; renewal++) {
      original.emit(
        DownloadTransportStatus.failed,
        failureCategory: DownloadFailureCategory.sourceExpired,
      );
      await _until(() => original.resumeCalls == renewal);
      for (var i = 0; i < 4; i++) {
        original.emit(DownloadTransportStatus.running, progress: .6);
      }
    }
    original.emit(
      DownloadTransportStatus.failed,
      failureCategory: DownloadFailureCategory.sourceExpired,
    );
    await _until(
      () => (f.manager.snapshotFor(request.logicalId)?.failureMessage ?? '')
          .contains('Max source refresh attempts'),
    );
    expect(original.replaceCalls, 3);
    expect(original.resumeCalls, 3);
    expect(f.resolver.calls, 4);
    expect(
      (await f.store.get(request.logicalId))?.intent,
      DownloadUserIntent.failed,
    );
  });

  test(
    'pause requested while source resolution fails remains durably paused',
    () async {
      f.gateway.renewable = true;
      final request = f.request('pause-failed-resolve');
      await f.manager.start(request);
      final original = f.gateway.handles.values.single as _RenewableHandle;
      final entered = Completer<void>();
      final release = Completer<void>();
      f.resolver.beforeResolve = (_) async {
        entered.complete();
        await release.future;
        throw StateError('provider unavailable');
      };
      original.emit(
        DownloadTransportStatus.failed,
        failureCategory: DownloadFailureCategory.sourceExpired,
      );
      await entered.future.timeout(const Duration(seconds: 3));
      final pause = f.manager.pause(request.logicalId);
      release.complete();
      await pause;
      expect(
        (await f.store.get(request.logicalId))?.intent,
        DownloadUserIntent.paused,
      );
      expect(original.resumeCalls, 0);
      expect(original.cancelCalls, 0);
      expect(f.gateway.started, hasLength(1));
    },
  );
}

final class _Fixture {
  _Fixture(this.root);
  final Directory root;
  final store = InMemoryLogicalDownloadStoreV2();
  final gateway = _Gateway();
  final resolver = _Resolver();
  late final manager = DownloadManagerV2(
    store: store,
    gateway: gateway,
    sourceResolver: resolver,
    maxConcurrentDownloads: () => limit,
  );
  int limit = 2;

  static Future<_Fixture> create() async =>
      _Fixture(await Directory.systemTemp.createTemp('aw-deep-manager-'));

  DownloadStartRequestV2 request(String episode) => DownloadStartRequestV2(
    logicalId: logicalDownloadIdFor(
      animeId: 'audit-series',
      episodeKey: episode,
      variantKey: '1080p',
    ),
    mediaId: 'audit-series',
    unitKey: episode,
    variantKey: '1080p',
    destinationPath: '${root.path}/$episode.mp4',
    sourceDescriptor: {'episode': episode},
    expectedBytes: 100,
    allowPause: true,
    retries: 2,
    parallelChunks: 1,
  );
}

final class _Resolver implements DownloadSourceResolverV2 {
  int calls = 0;
  Future<void> Function(Map<String, Object?> descriptor)? beforeResolve;
  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    calls++;
    await beforeResolve?.call(descriptor);
    return ResolvedDownloadSourceV2(
      url:
          'https://example.invalid/${descriptor['episode']}.mp4?generation=$calls',
      headers: const {},
      expectedBytes: 100,
    );
  }
}

final class _Gateway implements BackgroundDownloaderGateway {
  bool renewable = false;
  final started = <DownloadTaskSpecV2>[];
  final handles = <String, _Handle>{};
  final removed = <String>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      handles.values.toList();
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async =>
      handles[taskId];
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    started.add(spec);
    return handles[spec.taskId] = renewable
        ? _RenewableHandle(spec.taskId)
        : _Handle(spec.taskId);
  }

  @override
  Future<void> removeTracking(String taskId) async {
    removed.add(taskId);
  }

  Future<void> dispose() async {
    for (final handle in handles.values) {
      await handle.controller.close();
    }
  }
}

class _Handle implements DownloadTransportHandle {
  _Handle(this.taskId)
    : _current = DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: 0,
        totalBytes: 100,
        transferredBytes: 0,
      );
  @override
  final String taskId;
  final controller = StreamController<DownloadTransportSnapshot>.broadcast(
    sync: true,
  );
  DownloadTransportSnapshot _current;
  Object? pauseError;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int cancelCalls = 0;
  @override
  DownloadTransportSnapshot get current => _current;
  @override
  Stream<DownloadTransportSnapshot> get snapshots => controller.stream;
  @override
  Future<bool> pause() async {
    pauseCalls++;
    if (pauseError case final error?) throw error;
    emit(DownloadTransportStatus.paused);
    return true;
  }

  @override
  Future<bool> resume() async {
    resumeCalls++;
    emit(DownloadTransportStatus.running);
    return true;
  }

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    emit(DownloadTransportStatus.canceled);
    return true;
  }

  void emit(
    DownloadTransportStatus status, {
    double? progress,
    DownloadFailureCategory? failureCategory,
  }) {
    final fraction = progress ?? current.progress;
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: status,
      progress: fraction,
      transferredBytes: (fraction * 100).round(),
      totalBytes: 100,
      failureCategory: failureCategory,
    );
    controller.add(_current);
  }
}

final class _RenewableHandle extends _Handle
    implements SourceRenewingDownloadTransportHandleV2 {
  _RenewableHandle(super.taskId);
  @override
  void interruptSourceRenewal() {}
  int replaceCalls = 0;
  bool replaceAccepted = true;
  @override
  Future<bool> replaceSource({
    required String url,
    required Map<String, String> headers,
    int? expectedBytes,
  }) async {
    replaceCalls++;
    if (!replaceAccepted) return false;
    emit(DownloadTransportStatus.paused);
    return true;
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline))
      throw TimeoutException('Condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
