import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  test('local readiness reports initialization failure and retries', () async {
    final gateway = _Gateway()..failInitialize = true;
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: gateway,
      sourceResolver: _PendingResolver(),
    );
    try {
      await expectLater(
        manager.records.first.timeout(const Duration(seconds: 2)),
        throwsStateError,
      );
      gateway.failInitialize = false;
      expect(
        await manager.records.first.timeout(const Duration(seconds: 2)),
        isEmpty,
      );
    } finally {
      await manager.dispose();
    }
  });

  test('disposing before local readiness releases waiting readers', () async {
    final blocked = Completer<void>();
    final gateway = _Gateway()..initializeGate = blocked.future;
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: gateway,
      sourceResolver: _PendingResolver(),
    );
    final expectation = expectLater(
      manager.records.first.timeout(const Duration(seconds: 2)),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);
    await manager.dispose();
    await expectation;
    blocked.complete();
    await manager.initialize();
  });

  test('canceling a startup reader does not turn disposal into an error', () async {
    final blocked = Completer<void>();
    final gateway = _Gateway()..initializeGate = blocked.future;
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: gateway,
      sourceResolver: _PendingResolver(),
    );
    final subscription = manager.records.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    final cancellation = subscription.cancel();
    try {
      await manager.dispose();
      await cancellation.timeout(const Duration(seconds: 2));
    } finally {
      blocked.complete();
      await manager.initialize();
    }
  });
  for (final mode in ['warm', 'cold', 'dispose']) {
    final cold = mode != 'warm';
    test(
      switch (mode) {
        'cold' => 'cold completed deletion and listing do not wait for unrelated source recovery',
        'dispose' => 'disposing during deferred startup prevents a late writer',
        _ =>
          'completed deletion never rediscovers an already settled transport',
      },
      () async {
        final root = Directory.systemTemp.createTempSync('aw-offline-delete-');
        final previous = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(root.path);
        final store = InMemoryLogicalDownloadStoreV2();
        final gateway = _Gateway();
        final resolver = _PendingResolver();
        final manager = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: resolver,
        );
        final file = File(p.join(root.path, 'anime', 'Show', 'done.mp4'));
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync([1, 2, 3]);
        final completed = _record(file.path, 'done', completed: true);
        await store.put(completed);
        final active = _record(
          p.join(root.path, 'anime', 'Other', 'pending.mp4'),
          'pending',
        );
        if (cold) {
          await store.put(active);
        } else {
          await manager.initialize();
        }
        gateway.blockAttach = mode != 'dispose';
        Future<void>? deletion;
        try {
          deletion = manager.delete(completed.logicalId);
          await deletion.timeout(const Duration(seconds: 2));
          expect(file.existsSync(), isFalse);
          expect(await store.get(completed.logicalId), isNull);
          if (cold) {
            await resolver.entered.future.timeout(const Duration(seconds: 2));
            expect(resolver.result.isCompleted, isFalse);
            final records = await manager.records.first.timeout(
              const Duration(seconds: 2),
            );
            expect(
              records.map((record) => record.logicalId),
              contains(active.logicalId),
            );
            expect(
              records.map((record) => record.logicalId),
              isNot(contains(completed.logicalId)),
            );
          }
          expect(gateway.attachCalls, isEmpty);
          if (mode == 'dispose') {
            await manager.dispose();
            resolver.result.complete(
              const ResolvedDownloadSourceV2(
                url: 'https://example.invalid/video.mp4',
                headers: {},
              ),
            );
            await manager.initialize();
            expect(gateway.starts, 0);
            expect((await store.get(active.logicalId))?.generation, 1);
            expect((await store.get(active.logicalId))?.failureMessage, isNull);
          }
        } finally {
          gateway.releaseAttach.complete();
          if (!resolver.result.isCompleted) {
            resolver.result.completeError(
              StateError('test-only offline source'),
            );
          }
          await manager.initialize();
          await deletion?.catchError((_) {});
          expect(await store.get(completed.logicalId), isNull);
          await manager.dispose();
          PathProviderPlatform.instance = previous;
          root.deleteSync(recursive: true);
        }
      },
    );
  }
}

LogicalDownloadRecordV2 _record(
  String path,
  String episode, {
  bool completed = false,
}) {
  final id = logicalDownloadIdFor(
    animeId: episode,
    episodeKey: episode,
    variantKey: 'original',
  );
  return LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: id,
    mediaKind: DownloadMediaKind.videoEpisode,
    mediaId: episode,
    unitKey: episode,
    variantKey: 'original',
    generation: 1,
    taskId: taskIdForGeneration(id, 1),
    intent: DownloadUserIntent.active,
    destinationPath: path,
    sourceDescriptor: const {},
    expectedBytes: completed ? 3 : null,
    completedAtMillis: completed ? 2 : null,
    updatedAtMillis: completed ? 2 : 1,
  );
}

final class _PendingResolver implements DownloadSourceResolverV2 {
  final entered = Completer<void>();
  final result = Completer<ResolvedDownloadSourceV2>();
  _PendingResolver() {
    unawaited(result.future.then<void>((_) {}, onError: (Object _) {}));
  }
  @override
  Future<ResolvedDownloadSourceV2> resolve(Map<String, Object?> descriptor) {
    if (!entered.isCompleted) entered.complete();
    return result.future;
  }
}

final class _Gateway implements BackgroundDownloaderGateway {
  bool blockAttach = false;
  bool failInitialize = false;
  Future<void>? initializeGate;
  int starts = 0;
  final releaseAttach = Completer<void>();
  final attachCalls = <String>[];
  @override
  Future<void> initialize() async {
    if (failInitialize) throw StateError('test-only startup failure');
    await initializeGate;
  }

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [];
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async {
    attachCalls.add(taskId);
    if (blockAttach) await releaseAttach.future;
    return null;
  }

  @override
  Future<void> removeTracking(String taskId) async {}
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    starts++;
    throw StateError('Unexpected start');
  }
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getDownloadsPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}
