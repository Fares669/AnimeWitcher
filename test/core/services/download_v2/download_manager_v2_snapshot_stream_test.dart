import 'dart:async';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('publishes package-neutral live snapshot updates for presentation', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _Gateway();
    final logicalId = logicalDownloadIdFor(
      animeId: 'anime:1',
      episodeKey: 'episode:7',
      variantKey: 'sub:1080p',
    );
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: _Resolver(),
    );
    addTearDown(manager.dispose);

    final seen = <DownloadSnapshotUpdateV2>[];
    final subscription = manager.snapshots.listen(seen.add);
    addTearDown(subscription.cancel);

    await manager.start(
      DownloadStartRequestV2(
        logicalId: logicalId,
        animeId: 'anime:1',
        episodeKey: 'episode:7',
        variantKey: 'sub:1080p',
        destinationPath: 'AnimeWitcher/Downloads/a/7.mp4',
        sourceDescriptor: const <String, Object?>{'providerId': 'provider'},
        allowPause: true,
        retries: 2,
        parallelChunks: 5,
      ),
    );

    final taskId = gateway.started.single.taskId;
    gateway.handle(taskId).emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: 0.42,
        transferredBytes: 42,
        totalBytes: 100,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      seen,
      contains(
        predicate<DownloadSnapshotUpdateV2>(
          (update) =>
              update.logicalId == logicalId &&
              update.snapshot.taskId == taskId &&
              update.snapshot.progress == 0.42 &&
              update.snapshot.totalBytes == 100,
        ),
      ),
    );
  });
}

final class _Gateway implements BackgroundDownloaderGateway {
  final List<DownloadTaskSpecV2> started = <DownloadTaskSpecV2>[];
  final Map<String, _Handle> _handles = <String, _Handle>{};

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    started.add(spec);
    final handle = _Handle(
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
  Future<DownloadTransportHandle?> attach(String taskId) async => _handles[taskId];

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      _handles.values.toList(growable: false);

  @override
  Future<void> removeTracking(String taskId) async {}

  _Handle handle(String taskId) => _handles[taskId]!;
}

final class _Handle implements DownloadTransportHandle {
  _Handle(this._current);

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
}

final class _Resolver implements DownloadSourceResolverV2 {
  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> sourceDescriptor,
  ) async {
    return const ResolvedDownloadSourceV2(
      url: 'https://example.invalid/video.mp4',
      headers: <String, String>{},
    );
  }
}
