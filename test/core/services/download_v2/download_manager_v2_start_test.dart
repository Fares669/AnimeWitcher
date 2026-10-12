import 'dart:async';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_v2_test_support.dart';

void main() {
  test('duplicate start creates one writer', () async {
    final gateway = _FakeGateway();
    final resolver = StaticSourceResolverV2(
      headers: const <String, String>{'referer': 'https://example.invalid/'},
      expectedBytes: 123456,
    );
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: gateway,
      sourceResolver: resolver,
    );
    final request = _request();

    await Future.wait(<Future<DownloadTransportSnapshot>>[
      manager.start(request),
      manager.start(request),
    ]);

    expect(gateway.startedSpecs, hasLength(1));
    expect(
      gateway.startedSpecs.single.taskId,
      taskIdForGeneration(request.logicalId, 1),
    );
    expect(resolver.calls, 1);
  });

  test('duplicate queued start cannot replace its durable destination', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _FakeGateway();
    final resolver = StaticSourceResolverV2();
    var capacity = 1;
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
      maxConcurrentDownloads: () => capacity,
    );
    addTearDown(manager.dispose);

    final owner = _request();
    final blocker = DownloadStartRequestV2(
      logicalId: logicalDownloadIdFor(
        animeId: 'anilist:22',
        episodeKey: '13',
        variantKey: 'sub:1080p',
      ),
      mediaId: 'anilist:22',
      unitKey: '13',
      variantKey: 'sub:1080p',
      destinationPath: 'downloads/anime/blocker.mp4',
      sourceDescriptor: const <String, Object?>{'providerId': 'other'},
      allowPause: true,
      retries: 2,
      parallelChunks: 1,
    );
    final conflictingStart = DownloadStartRequestV2(
      logicalId: owner.logicalId,
      mediaId: owner.mediaId,
      unitKey: owner.unitKey,
      variantKey: owner.variantKey,
      destinationPath: 'downloads/anime/WRONG.mp4',
      sourceDescriptor: const <String, Object?>{'providerId': 'different'},
      allowPause: owner.allowPause,
      retries: owner.retries,
      parallelChunks: owner.parallelChunks,
    );

    await manager.start(blocker);
    expect((await manager.start(owner)).status, DownloadTransportStatus.queued);
    expect(
      (await manager.start(conflictingStart)).status,
      DownloadTransportStatus.queued,
    );

    capacity = 2;
    await manager.reconcileAdmission();

    expect(gateway.startedSpecs, hasLength(2));
    expect(gateway.startedSpecs.last.destinationPath, owner.destinationPath);
    expect(
      (await store.get(owner.logicalId))?.destinationPath,
      owner.destinationPath,
    );
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
    mediaId: 'anilist:21',
    unitKey: '12',
    variantKey: 'sub:1080p',
    destinationPath: 'downloads/anime/episode-12.mp4',
    sourceDescriptor: const <String, Object?>{
      'providerId': 'provider.example',
      'trackingUrl': '/anime/21/12',
    },
    expectedBytes: 123456,
    allowPause: true,
    retries: 2,
    parallelChunks: 5,
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
    return _handles.putIfAbsent(
      spec.taskId,
      () => _FakeHandle(
        DownloadTransportSnapshot(
          taskId: spec.taskId,
          status: DownloadTransportStatus.running,
          progress: 0,
        ),
      ),
    );
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
}

final class _FakeHandle implements DownloadTransportHandle {
  _FakeHandle(this._current);

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast();

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

  void dispose() {
    unawaited(_controller.close());
  }
}
