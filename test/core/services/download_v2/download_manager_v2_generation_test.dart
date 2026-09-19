import 'dart:async';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_v2_test_support.dart';

void main() {
  test('late old-generation event is ignored', () async {
    final gateway = _FakeGateway();
    final resolver = StaticSourceResolverV2();
    final store = InMemoryLogicalDownloadStoreV2();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    final request = _request();

    await manager.start(request);
    final oldTaskId = gateway.startedSpecs.single.taskId;

    await manager.restart(request.logicalId);
    final newTaskId = gateway.startedSpecs.last.taskId;
    expect(newTaskId, isNot(oldTaskId));

    gateway.emit(oldTaskId, DownloadTransportStatus.complete);
    await Future<void>.delayed(Duration.zero);

    final current = manager.snapshotFor(request.logicalId);
    final durable = await store.get(request.logicalId);
    expect(current, isNotNull);
    expect(current!.taskId, newTaskId);
    expect(current.taskId, isNot(oldTaskId));
    expect(durable?.taskId, newTaskId);
    expect(durable?.completedAtMillis, isNull);
    expect(resolver.calls, 2);
  });
}

DownloadStartRequestV2 _request() {
  final logicalId = logicalDownloadIdFor(
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
  );
  return DownloadStartRequestV2(
    logicalId: logicalId,
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
    destinationPath: 'downloads/anime/episode-12.mp4',
    sourceDescriptor: const <String, Object?>{
      'providerId': 'provider.example',
      'trackingUrl': '/anime/21/12',
    },
    expectedBytes: 123456,
    allowPause: true,
    retries: 2,
    parallelChunks: 1,
  );
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

  void emit(String taskId, DownloadTransportStatus status) {
    _handles[taskId]?.emit(status);
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
  Future<bool> cancel() async {
    emit(DownloadTransportStatus.canceled);
    return true;
  }

  void emit(DownloadTransportStatus status) {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: status,
      progress: status == DownloadTransportStatus.complete ? 1 : 0.5,
    );
    _controller.add(_current);
  }

  void dispose() {
    unawaited(_controller.close());
  }
}
