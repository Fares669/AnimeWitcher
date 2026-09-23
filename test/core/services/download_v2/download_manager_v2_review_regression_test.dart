import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_v2_test_support.dart';

void main() {
  group('deep-review reliability regressions', () {
    test('startup demotes completed record when final artifact is missing', () async {
      final temp = await Directory.systemTemp.createTemp('aw-v2-missing-complete-');
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
      expect(restored.failureCategory, DownloadFailureCategory.integrity);
      expect(manager.snapshotFor(logicalId)?.status, isNot(DownloadTransportStatus.complete));
      expect(gateway.startedSpecs, isEmpty);
    });

    test('integrity mismatch removes invalid final artifact before retry', () async {
      final temp = await Directory.systemTemp.createTemp('aw-v2-corrupt-final-');
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
    });

    test('failed obsolete cancel does not publish a replacement generation', () async {
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
    });

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
      expect(manager.snapshotFor(request.logicalId)?.status,
          DownloadTransportStatus.running);
      expect(gateway.startedSpecs, hasLength(1));
      expect(gateway.handleFor(taskId), isNotNull);
    });
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
    animeId: 'anime:review',
    episodeKey: logicalId.value,
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
    animeId: 'anime:review',
    episodeKey: logicalId.value,
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
  Future<DownloadTransportHandle?> attach(String taskId) async => _handles[taskId];

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

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async => cancelResult;

  void emit(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    _controller.add(snapshot);
  }
}
