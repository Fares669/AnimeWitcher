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
  group('completion integrity gate', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('animewitcher-v2-complete-');
    });

    tearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    test('missing file does not commit logical completion', () async {
      final f = _fixture('${temp.path}/missing.mp4', expectedBytes: 4);
      await f.manager.start(f.request);

      f.gateway.emitComplete(f.gateway.startedSpecs.single.taskId);
      final record = await _waitForRecord(
        f.store,
        f.request.logicalId,
        (value) => value?.failureCategory == DownloadFailureCategory.integrity,
      );

      expect(record?.completedAtMillis, isNull);
      expect(record?.failureCategory, DownloadFailureCategory.integrity);
      expect(record?.failureMessage, 'missing');
      expect(
        f.manager.snapshotFor(f.request.logicalId)?.status,
        DownloadTransportStatus.failed,
      );
    });

    test('empty file does not commit logical completion', () async {
      final file = File('${temp.path}/empty.mp4');
      await file.create(recursive: true);
      final f = _fixture(file.path, expectedBytes: 4);
      await f.manager.start(f.request);

      f.gateway.emitComplete(f.gateway.startedSpecs.single.taskId);
      final record = await _waitForRecord(
        f.store,
        f.request.logicalId,
        (value) => value?.failureCategory == DownloadFailureCategory.integrity,
      );

      expect(record?.completedAtMillis, isNull);
      expect(record?.failureMessage, 'empty');
    });

    test('trustworthy size mismatch does not commit logical completion', () async {
      final file = File('${temp.path}/mismatch.mp4');
      await file.writeAsBytes(<int>[1, 2, 3], flush: true);
      final f = _fixture(file.path, expectedBytes: 4);
      await f.manager.start(f.request);

      f.gateway.emitComplete(f.gateway.startedSpecs.single.taskId);
      final record = await _waitForRecord(
        f.store,
        f.request.logicalId,
        (value) => value?.failureCategory == DownloadFailureCategory.integrity,
      );

      expect(record?.completedAtMillis, isNull);
      expect(record?.failureMessage, 'size-mismatch');
    });

    test('valid final file is the only path that commits completion', () async {
      final file = File('${temp.path}/valid.mp4');
      await file.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
      final f = _fixture(file.path, expectedBytes: 4, nowMillis: () => 777);
      await f.manager.start(f.request);

      f.gateway.emitComplete(f.gateway.startedSpecs.single.taskId);
      final record = await _waitForRecord(
        f.store,
        f.request.logicalId,
        (value) => value?.completedAtMillis != null,
      );

      expect(record?.completedAtMillis, 777);
      expect(record?.failureCategory, isNull);
      expect(record?.failureMessage, isNull);
      expect(
        f.manager.snapshotFor(f.request.logicalId)?.status,
        DownloadTransportStatus.complete,
      );
    });
  });
}

_Fixture _fixture(
  String destinationPath, {
  required int expectedBytes,
  int Function()? nowMillis,
}) {
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
      'trackingUrl': '/anime/21/12',
    },
    expectedBytes: expectedBytes,
    allowPause: true,
    retries: 2,
    parallelChunks: 1,
  );
  final store = InMemoryLogicalDownloadStoreV2();
  final gateway = _FakeGateway();
  final manager = DownloadManagerV2(
    store: store,
    gateway: gateway,
    sourceResolver: StaticSourceResolverV2(expectedBytes: expectedBytes),
    nowMillis: nowMillis,
  );
  return _Fixture(
    request: request,
    store: store,
    gateway: gateway,
    manager: manager,
  );
}

Future<LogicalDownloadRecordV2?> _waitForRecord(
  InMemoryLogicalDownloadStoreV2 store,
  DownloadLogicalId logicalId,
  bool Function(LogicalDownloadRecordV2? value) done,
) async {
  LogicalDownloadRecordV2? value;
  for (var attempt = 0; attempt < 50; attempt++) {
    value = await store.get(logicalId);
    if (done(value)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return value;
}

final class _Fixture {
  const _Fixture({
    required this.request,
    required this.store,
    required this.gateway,
    required this.manager,
  });

  final DownloadStartRequestV2 request;
  final InMemoryLogicalDownloadStoreV2 store;
  final _FakeGateway gateway;
  final DownloadManagerV2 manager;
}

final class _FakeGateway implements BackgroundDownloaderGateway {
  final List<DownloadTaskSpecV2> startedSpecs = <DownloadTaskSpecV2>[];
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
    _handles.remove(taskId)?.dispose();
  }

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

final class _FakeHandle implements DownloadTransportHandle {
  _FakeHandle(this._current);

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
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async => true;

  void emit(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    _controller.add(snapshot);
  }

  void dispose() {
    unawaited(_controller.close());
  }
}
