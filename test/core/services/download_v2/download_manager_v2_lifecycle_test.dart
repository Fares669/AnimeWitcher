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

_Fixture _fixture({String destinationPath = 'downloads/anime/episode-12.mp4'}) {
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
    parallelChunks: 1,
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
    return onPause?.call() ?? true;
  }

  @override
  Future<bool> resume() async {
    resumeCalls++;
    return onResume?.call() ?? true;
  }

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    return onCancel?.call() ?? true;
  }

  void emit(DownloadTransportStatus status) {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: status,
      progress: status == DownloadTransportStatus.complete ? 1 : 0.5,
    );
    _controller.add(_current);
  }
}
