import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'download_v2_test_support.dart';

void main() {
  group('deep-review reliability regressions', () {

    test('deleting a legacy duplicate never removes another record\'s final file', () async {
      final temp = await Directory.systemTemp.createTemp('aw-v2-owner-delete-');
      addTearDown(() => temp.delete(recursive: true));
      final target = File('${temp.path}/shared.mp4');
      await target.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      final owner = _record(
        logicalId: _logicalId('owner-delete'),
        destinationPath: target.path,
        completedAtMillis: 1,
        expectedBytes: 4,
      );
      final duplicate = _record(
        logicalId: _logicalId('duplicate-delete'),
        destinationPath: target.path,
        completedAtMillis: 1,
        expectedBytes: 4,
      );
      final store = InMemoryLogicalDownloadStoreV2();
      await store.put(owner);
      await store.put(duplicate);
      final manager = DownloadManagerV2(
        store: store,
        gateway: _Gateway(),
        sourceResolver: StaticSourceResolverV2(),
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.delete(duplicate.logicalId);
      expect(await target.readAsBytes(), <int>[1, 2, 3, 4]);
      expect((await store.get(owner.logicalId))?.completedAtMillis, isNotNull);
      await manager.delete(owner.logicalId);
      expect(await target.exists(), isFalse);
    });

    test('invalid completed duplicate cannot delete a valid earlier owner file', () async {
      final temp = await Directory.systemTemp.createTemp('aw-v2-owner-startup-');
      addTearDown(() => temp.delete(recursive: true));
      final target = File('${temp.path}/shared.mp4');
      await target.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      final owner = _record(
        logicalId: _logicalId('owner-startup'),
        destinationPath: target.path,
        completedAtMillis: 1,
        expectedBytes: 4,
      );
      final duplicate = _record(
        logicalId: _logicalId('duplicate-startup'),
        destinationPath: target.path,
        completedAtMillis: 1,
        expectedBytes: 5,
      );
      final store = InMemoryLogicalDownloadStoreV2();
      await store.put(owner);
      await store.put(duplicate);
      final manager = DownloadManagerV2(
        store: store,
        gateway: _Gateway(),
        sourceResolver: StaticSourceResolverV2(),
      );
      addTearDown(manager.dispose);

      await manager.initialize();
      expect(await target.readAsBytes(), <int>[1, 2, 3, 4]);
      expect((await store.get(owner.logicalId))?.completedAtMillis, isNotNull);
      expect((await store.get(duplicate.logicalId))?.intent, DownloadUserIntent.failed);
    });

    for (final sameDestination in [false, true]) {
      test(
        'in-flight rejected cancel preserves ${sameDestination ? "destination" : "slot"} ownership',
        () async {
          final store = InMemoryLogicalDownloadStoreV2();
          final gateway = _Gateway();
          final manager = DownloadManagerV2(
            store: store,
            gateway: gateway,
            sourceResolver: StaticSourceResolverV2(),
            maxConcurrentDownloads: () => sameDestination ? 2 : 1,
          );
          addTearDown(manager.dispose);
          final first = _request(
            logicalId: _logicalId('canceling'),
            destinationPath: '/tmp/aw-v2-canceling.mp4',
          );
          final second = _request(
            logicalId: _logicalId('cancel-waiter'),
            destinationPath: sameDestination
                ? first.destinationPath
                : '/tmp/aw-v2-cancel-waiter.mp4',
          );
          await manager.start(first);
          final entered = Completer<void>();
          final accepted = Completer<bool>();
          gateway.handleFor(gateway.startedSpecs.single.taskId)!.onCancel = () {
            entered.complete();
            return accepted.future;
          };
          final failedCancel = expectLater(
            manager.cancel(first.logicalId),
            throwsStateError,
          );
          await entered.future;
          try {
            final start = manager.start(second);
            if (sameDestination) {
              final failedStart = expectLater(start, throwsStateError);
              await Future<void>.delayed(Duration.zero);
              expect(gateway.startedSpecs, hasLength(1));
              accepted.complete(false);
              await failedStart;
            } else {
              expect((await start).status, DownloadTransportStatus.queued);
              expect(gateway.startedSpecs, hasLength(1));
            }
          } finally {
            if (!accepted.isCompleted) accepted.complete(false);
            await failedCancel;
          }
          await manager.reconcileAdmission();
          expect(gateway.startedSpecs, hasLength(1));
          expect(
            (await store.get(first.logicalId))?.intent,
            DownloadUserIntent.active,
          );
        },
      );
    }

    for (final kind in [
      'documents',
      'media-root',
      'title',
      'chapter',
      'symlink',
    ]) {
      test(
        'manga deletion protects $kind according to chapter ownership',
        () async {
          if (kind == 'symlink' && Platform.isWindows) return;
          final temp = await Directory.systemTemp.createTemp('aw-v2-delete-');
          addTearDown(() => temp.delete(recursive: true));
          final original = PathProviderPlatform.instance;
          PathProviderPlatform.instance = _DownloadPathProvider(temp.path);
          addTearDown(() => PathProviderPlatform.instance = original);
          final root = Directory('${temp.path}/manga');
          final title = Directory('${root.path}/title');
          final chapter = Directory('${title.path}/chapter');
          await chapter.create(recursive: true);
          final id = _logicalId('delete-$kind');
          final manifest = MangaChapterManifestV2(
            version: MangaChapterManifestV2.currentVersion,
            mangaId: 'anime:review',
            chapterId: id.value,
            pageCount: 1,
            completedIndexes: const {},
            isComplete: false,
          );
          await manifest.writeTo(chapter);
          final outside = Directory('${temp.path}/outside');
          await outside.create();
          await manifest.writeTo(outside);
          if (kind == 'symlink') {
            await Link('${title.path}/link').create(outside.path);
          }
          final destination = switch (kind) {
            'documents' => temp.path,
            'media-root' => root.path,
            'title' => title.path,
            'chapter' => chapter.path,
            _ => '${title.path}/link',
          };
          final store = InMemoryLogicalDownloadStoreV2();
          await store.put(
            _record(logicalId: id, destinationPath: destination).copyWith(
              mediaKind: DownloadMediaKind.mangaChapter,
              intent: DownloadUserIntent.failed,
            ),
          );
          final manager = DownloadManagerV2(
            store: store,
            gateway: _Gateway(),
            sourceResolver: StaticSourceResolverV2(),
          );
          addTearDown(manager.dispose);

          await manager.delete(id);

          expect(await Directory(destination).exists(), kind != 'chapter');
          expect(await outside.exists(), isTrue);
        },
      );
    }

    test(
      'in-flight rejected pause cannot admit a second live writer',
      () async {
        final store = InMemoryLogicalDownloadStoreV2();
        final gateway = _Gateway();
        final manager = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: StaticSourceResolverV2(),
          maxConcurrentDownloads: () => 1,
        );
        addTearDown(manager.dispose);
        final first = _request(
          logicalId: _logicalId('pausing'),
          destinationPath: '/tmp/aw-v2-pausing.mp4',
        );
        final second = _request(
          logicalId: _logicalId('waiting-pause'),
          destinationPath: '/tmp/aw-v2-waiting-pause.mp4',
        );
        await manager.start(first);
        final entered = Completer<void>();
        final accepted = Completer<bool>();
        gateway.handleFor(gateway.startedSpecs.single.taskId)!.onPause = () {
          entered.complete();
          return accepted.future;
        };
        final pause = manager.pause(first.logicalId);
        final failedPause = expectLater(pause, throwsStateError);
        await entered.future;
        try {
          final queued = await manager.start(second);
          expect(queued.status, DownloadTransportStatus.queued);
          expect(gateway.startedSpecs, hasLength(1));
        } finally {
          accepted.complete(false);
          await failedPause;
        }
        await manager.reconcileAdmission();
        expect(gateway.startedSpecs, hasLength(1));
        expect(
          (await store.get(first.logicalId))?.intent,
          DownloadUserIntent.active,
        );
      },
    );

    test(
      'failed startup record can restart from durable source metadata',
      () async {
        final store = InMemoryLogicalDownloadStoreV2();
        final id = _logicalId('failed-startup');
        await store.put(
          _record(
            logicalId: id,
            destinationPath: '/tmp/aw-v2-failed-startup.mp4',
          ).copyWith(intent: DownloadUserIntent.failed),
        );
        final gateway = _Gateway();
        final manager = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: StaticSourceResolverV2(),
        );
        addTearDown(manager.dispose);
        await manager.initialize();
        expect(gateway.startedSpecs, isEmpty);

        await manager.restart(id);

        expect(gateway.startedSpecs, hasLength(1));
        expect((await store.get(id))?.generation, 2);
        expect((await store.get(id))?.intent, DownloadUserIntent.active);
      },
    );

    test(
      'transport failure stays failed across startup and late completion',
      () async {
        final store = InMemoryLogicalDownloadStoreV2();
        final gateway = _Gateway();
        final manager = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: StaticSourceResolverV2(),
        );
        final request = _request(
          logicalId: _logicalId('failed-transport'),
          destinationPath: '/tmp/aw-v2-failed-transport.mp4',
        );
        await manager.start(request);
        final taskId = gateway.startedSpecs.single.taskId;
        gateway
            .handleFor(taskId)!
            .emit(
              DownloadTransportSnapshot(
                taskId: taskId,
                status: DownloadTransportStatus.failed,
                progress: 0.5,
                failureCategory: DownloadFailureCategory.transport,
                failureMessage: 'offline',
              ),
            );
        await _waitFor(
          () async =>
              (await store.get(request.logicalId))?.intent ==
              DownloadUserIntent.failed,
        );
        gateway.emitComplete(taskId);
        await manager.dispose();
        final reopened = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: StaticSourceResolverV2(),
        );
        addTearDown(reopened.dispose);
        await reopened.initialize();
        expect(gateway.startedSpecs, hasLength(1));
        expect((await store.get(request.logicalId))?.completedAtMillis, isNull);
        expect((await store.get(request.logicalId))?.failureMessage, 'offline');
        expect(
          reopened.snapshotFor(request.logicalId)?.status,
          DownloadTransportStatus.failed,
        );
      },
    );

    for (final throws in [false, true]) {
      test(
        'pause ${throws ? "exception" : "rejection"} retains active writer truth',
        () async {
          final store = InMemoryLogicalDownloadStoreV2();
          final gateway = _Gateway();
          final manager = DownloadManagerV2(
            store: store,
            gateway: gateway,
            sourceResolver: StaticSourceResolverV2(),
          );
          addTearDown(manager.dispose);
          final request = _request(
            logicalId: _logicalId('pause-$throws'),
            destinationPath: '/tmp/aw-v2-pause-$throws.mp4',
          );
          await manager.start(request);
          final handle = gateway.handleFor(gateway.startedSpecs.single.taskId)!;
          handle.pauseResult = false;
          handle.pauseError = throws ? StateError('pause rejected') : null;

          await expectLater(manager.pause(request.logicalId), throwsStateError);

          expect(
            (await store.get(request.logicalId))?.intent,
            DownloadUserIntent.active,
          );
          expect(
            manager.snapshotFor(request.logicalId)?.status,
            DownloadTransportStatus.running,
          );
          expect(handle.cancelCalls, 0);
          expect(gateway.startedSpecs, hasLength(1));
        },
      );
    }

    test(
      'startup demotes completed record when final artifact is missing',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'aw-v2-missing-complete-',
        );
        addTearDown(() async {
          if (await temp.exists()) await temp.delete(recursive: true);
        });
        final destination = '${temp.path}${Platform.pathSeparator}missing.mp4';
        final logicalId = _logicalId('missing');
        final store = InMemoryLogicalDownloadStoreV2();
        await store.put(
          _record(
            logicalId: logicalId,
            destinationPath: destination,
            completedAtMillis: 100,
            expectedBytes: 4,
          ),
        );
        final gateway = _Gateway();
        final manager = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: StaticSourceResolverV2(expectedBytes: 4),
        );
        addTearDown(manager.dispose);

        await manager.initialize();

        final restored = await store.get(logicalId);
        expect(restored, isNotNull);
        expect(restored!.completedAtMillis, isNull);
        expect(restored.intent, DownloadUserIntent.failed);
        expect(restored.failureCategory, DownloadFailureCategory.integrity);
        expect(
          manager.snapshotFor(logicalId)?.status,
          isNot(DownloadTransportStatus.complete),
        );
        expect(gateway.startedSpecs, isEmpty);
      },
    );

    test(
      'integrity mismatch removes invalid final artifact before retry',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'aw-v2-corrupt-final-',
        );
        addTearDown(() async {
          if (await temp.exists()) await temp.delete(recursive: true);
        });
        final file = File('${temp.path}${Platform.pathSeparator}episode.mp4');
        await file.writeAsBytes(<int>[1, 2, 3], flush: true);
        final store = InMemoryLogicalDownloadStoreV2();
        final gateway = _Gateway();
        final resolver = StaticSourceResolverV2(expectedBytes: 4);
        final manager = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: resolver,
        );
        addTearDown(manager.dispose);
        final request = _request(
          logicalId: _logicalId('corrupt'),
          destinationPath: file.path,
          expectedBytes: 4,
        );

        await manager.start(request);
        gateway.emitComplete(gateway.startedSpecs.single.taskId);
        await _waitFor(
          () async =>
              (await store.get(request.logicalId))?.failureCategory ==
              DownloadFailureCategory.integrity,
        );

        expect(await file.exists(), isFalse);
        expect(
          manager.snapshotFor(request.logicalId)?.status,
          DownloadTransportStatus.failed,
        );
      },
    );

    test(
      'failed obsolete cancel does not publish a replacement generation',
      () async {
        final store = InMemoryLogicalDownloadStoreV2();
        final gateway = _Gateway();
        final resolver = StaticSourceResolverV2();
        final manager = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: resolver,
        );
        addTearDown(manager.dispose);
        final request = _request(
          logicalId: _logicalId('cancel-failure'),
          destinationPath: '/tmp/aw-v2-cancel-failure.mp4',
        );

        await manager.start(request);
        final firstTaskId = gateway.startedSpecs.single.taskId;
        final handle = gateway.handleFor(firstTaskId)!;
        handle.cancelResult = false;

        await expectLater(manager.restart(request.logicalId), throwsStateError);

        final durable = await store.get(request.logicalId);
        expect(durable, isNotNull);
        expect(durable!.generation, 1);
        expect(durable.taskId, firstTaskId);
        expect(gateway.startedSpecs, hasLength(1));
        expect(manager.snapshotFor(request.logicalId)?.taskId, firstTaskId);
      },
    );

    test('rejected user cancel restores the active download record', () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _Gateway();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: StaticSourceResolverV2(),
      );
      addTearDown(manager.dispose);
      final request = _request(
        logicalId: _logicalId('user-cancel-failure'),
        destinationPath: '/tmp/aw-v2-user-cancel-failure.mp4',
      );

      await manager.start(request);
      final taskId = gateway.startedSpecs.single.taskId;
      gateway.handleFor(taskId)!.cancelResult = false;

      await expectLater(manager.cancel(request.logicalId), throwsStateError);

      final record = await store.get(request.logicalId);
      expect(record, isNotNull);
      expect(record!.intent, DownloadUserIntent.active);
      expect(record.taskId, taskId);
      expect(
        manager.snapshotFor(request.logicalId)?.status,
        DownloadTransportStatus.running,
      );
      expect(gateway.startedSpecs, hasLength(1));
      expect(gateway.handleFor(taskId), isNotNull);
    });

    test(
      'source resolution failure persists an active missing writer as failed',
      () async {
        final store = InMemoryLogicalDownloadStoreV2();
        final gateway = _Gateway();
        final resolver = _FailAfterFirstSourceResolver();
        final manager = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: resolver,
        );
        addTearDown(manager.dispose);
        final request = _request(
          logicalId: _logicalId('source-resolution-failure'),
          destinationPath: '/tmp/aw-v2-source-resolution-failure.mp4',
        );

        await manager.start(request);
        final taskId = gateway.startedSpecs.single.taskId;
        gateway.handleFor(taskId)!.emit(
          DownloadTransportSnapshot(
            taskId: taskId,
            status: DownloadTransportStatus.missing,
            progress: 0.4,
          ),
        );

        await expectLater(manager.start(request), throwsStateError);

        final record = await store.get(request.logicalId);
        expect(record, isNotNull);
        expect(record!.intent, DownloadUserIntent.failed);
        expect(record.failureCategory, DownloadFailureCategory.unknown);
        expect(
          manager.snapshotFor(request.logicalId)?.status,
          DownloadTransportStatus.failed,
        );
      },
    );

    test(
      'scheduled admission promotion retries one transient coordinator error',
      () async {
        final store = InMemoryLogicalDownloadStoreV2();
        final gateway = _Gateway();
        final diagnostics = InMemoryDownloadDiagnosticsV2();
        var failNextLimitRead = false;
        final manager = DownloadManagerV2(
          store: store,
          gateway: gateway,
          sourceResolver: StaticSourceResolverV2(),
          diagnostics: diagnostics,
          maxConcurrentDownloads: () {
            if (failNextLimitRead) {
              failNextLimitRead = false;
              throw StateError('transient admission failure');
            }
            return 1;
          },
        );
        addTearDown(manager.dispose);
        final first = _request(
          logicalId: _logicalId('admission-owner'),
          destinationPath: '/tmp/aw-v2-admission-owner.mp4',
        );
        final second = _request(
          logicalId: _logicalId('admission-waiter'),
          destinationPath: '/tmp/aw-v2-admission-waiter.mp4',
        );

        await manager.start(first);
        expect((await manager.start(second)).status, DownloadTransportStatus.queued);
        failNextLimitRead = true;
        final firstTaskId = gateway.startedSpecs.single.taskId;
        gateway.handleFor(firstTaskId)!.emit(
          DownloadTransportSnapshot(
            taskId: firstTaskId,
            status: DownloadTransportStatus.failed,
            progress: 0.5,
            failureCategory: DownloadFailureCategory.transport,
            failureMessage: 'offline',
          ),
        );

        await _waitFor(() async => gateway.startedSpecs.length == 2);
        expect(
          diagnostics.transportEvents.any(
            (event) => event['event'] == 'admission.promotionFailed',
          ),
          isTrue,
        );
        expect(
          (await store.get(second.logicalId))?.awaitingAdmission,
          isFalse,
        );
      },
    );
  });
}

DownloadLogicalId _logicalId(String suffix) => logicalDownloadIdFor(
  animeId: 'anime:review',
  episodeKey: suffix,
  variantKey: 'sub|1080p',
);

DownloadStartRequestV2 _request({
  required DownloadLogicalId logicalId,
  required String destinationPath,
  int? expectedBytes,
}) {
  return DownloadStartRequestV2(
    logicalId: logicalId,
    mediaId: 'anime:review',
    unitKey: logicalId.value,
    variantKey: 'sub|1080p',
    destinationPath: destinationPath,
    sourceDescriptor: const <String, Object?>{
      'providerId': 'provider.example',
      'trackingUrl': '/anime/review/episode',
    },
    expectedBytes: expectedBytes,
    allowPause: true,
    retries: 2,
    parallelChunks: 1,
  );
}

LogicalDownloadRecordV2 _record({
  required DownloadLogicalId logicalId,
  required String destinationPath,
  int? completedAtMillis,
  int? expectedBytes,
}) {
  return LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: logicalId,
    mediaId: 'anime:review',
    unitKey: logicalId.value,
    variantKey: 'sub|1080p',
    generation: 1,
    taskId: taskIdForGeneration(logicalId, 1),
    intent: DownloadUserIntent.active,
    destinationPath: destinationPath,
    sourceDescriptor: const <String, Object?>{
      'providerId': 'provider.example',
      'trackingUrl': '/anime/review/episode',
    },
    expectedBytes: expectedBytes,
    completedAtMillis: completedAtMillis,
    updatedAtMillis: 1,
  );
}

Future<void> _waitFor(Future<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for V2 state transition');
}

final class _Gateway implements BackgroundDownloaderGateway {
  final List<DownloadTaskSpecV2> startedSpecs = <DownloadTaskSpecV2>[];
  final Map<String, _Handle> _handles = <String, _Handle>{};

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    startedSpecs.add(spec);
    final handle = _Handle(
      DownloadTransportSnapshot(
        taskId: spec.taskId,
        status: DownloadTransportStatus.running,
        progress: 0,
        totalBytes: null,
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
    _handles.remove(taskId);
  }

  _Handle? handleFor(String taskId) => _handles[taskId];

  void emitComplete(String taskId) {
    _handles[taskId]?.emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.complete,
        progress: 1,
      ),
    );
  }
}

final class _Handle implements DownloadTransportHandle {
  _Handle(this._current);

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);
  bool cancelResult = true;
  bool pauseResult = true;
  Object? pauseError;
  Future<bool> Function()? onPause;
  Future<bool> Function()? onCancel;
  int cancelCalls = 0;

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  @override
  Future<bool> pause() async {
    final error = pauseError;
    if (error != null) throw error;
    final action = onPause;
    if (action != null) return action();
    return pauseResult;
  }

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    final action = onCancel;
    if (action != null) return action();
    return cancelResult;
  }

  void emit(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    _controller.add(snapshot);
  }
}

final class _DownloadPathProvider extends PathProviderPlatform {
  _DownloadPathProvider(this.path);
  final String path;
  @override
  Future<String?> getDownloadsPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

final class _FailAfterFirstSourceResolver implements DownloadSourceResolverV2 {
  int calls = 0;

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    calls++;
    if (calls > 1) {
      throw StateError('source unavailable');
    }
    return const ResolvedDownloadSourceV2(
      url: 'https://example.invalid/video.mp4',
      headers: <String, String>{},
      expectedBytes: 100,
    );
  }
}
