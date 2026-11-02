import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new provider descriptors reject the old shared video identity', () async {
    final gateway = _Gateway();
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: gateway,
      sourceResolver: _Resolver(),
    );
    addTearDown(manager.dispose);
    final root = await Directory.systemTemp.createTemp('aw-provider-id-');
    addTearDown(() => root.delete(recursive: true));

    final incorrect = _request('com.animerift.provider', '${root.path}/rift.mp4',
        useLegacyId: true);
    await expectLater(manager.start(incorrect), throwsStateError);
    expect(gateway.started, isEmpty);
  });

  test('same media/episode IDs stay separate through refresh and restart', () async {
    final root = await Directory.systemTemp.createTemp('aw-provider-restart-');
    addTearDown(() => root.delete(recursive: true));
    final backend = <String, Object?>{};
    final store = InMemoryLogicalDownloadStoreV2(backend);
    final gateway = _Gateway();
    final resolver = _Resolver();
    final manager = DownloadManagerV2(
      store: store, gateway: gateway, sourceResolver: resolver,
    );
    addTearDown(manager.dispose);
    final native = _request('com.fares669.animewitcher.native',
        '${root.path}/native.mp4');
    final rift = _request('com.animerift.provider', '${root.path}/rift.mp4');

    expect(native.logicalId, isNot(rift.logicalId));
    expect(native.logicalId, logicalDownloadIdFor(
      animeId: '42', episodeKey: 'episode/1', variantKey: 'sub|1080p',
    ));
    await manager.start(native);
    await manager.start(rift);
    expect(gateway.started, hasLength(2));
    expect(gateway.started.map((spec) => spec.url), [
      'https://native.invalid/1.mp4', 'https://animerift.invalid/1.mp4',
    ]);
    expect((await store.all()).map((record) => record.logicalId).toSet(),
        {native.logicalId, rift.logicalId});

    gateway.expire(gateway.started.last.taskId);
    await gateway.waitForStarts(3);
    expect(gateway.started.last.url, 'https://animerift.invalid/2.mp4');
    expect(gateway.started.last.taskId, isNot(gateway.started[1].taskId));
    expect((await store.get(native.logicalId))?.generation, 1);
    expect((await store.get(rift.logicalId))?.generation, 2);
    expect((await store.get(rift.logicalId))?.sourceDescriptor['providerId'],
        'com.animerift.provider');

    final nativeBytes = File(native.destinationPath)..writeAsBytesSync([1, 2, 3]);
    final riftBytes = File(rift.destinationPath)..writeAsBytesSync([4, 5, 6]);
    await manager.dispose();

    // Simulate process recreation with durable JSON and no package handles or
    // network. Recovery must not resolve the other provider or move old files.
    final offlineResolver = _Resolver(offline: true);
    final offlineGateway = _Gateway();
    final restarted = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(backend),
      gateway: offlineGateway, sourceResolver: offlineResolver,
    );
    addTearDown(restarted.dispose);
    await restarted.initialize();
    expect(offlineResolver.providers.toSet(),
        {'com.fares669.animewitcher.native', 'com.animerift.provider'});
    expect(offlineGateway.started, isEmpty);
    expect((await store.get(native.logicalId))?.intent, DownloadUserIntent.active);
    expect((await store.get(rift.logicalId))?.intent, DownloadUserIntent.active);
    expect((await store.get(native.logicalId))?.sourceDescriptor['providerId'],
        'com.fares669.animewitcher.native');
    expect((await store.get(rift.logicalId))?.sourceDescriptor['providerId'],
        'com.animerift.provider');
    expect(nativeBytes.readAsBytesSync(), [1, 2, 3]);
    expect(riftBytes.readAsBytesSync(), [4, 5, 6]);
  });
}

DownloadStartRequestV2 _request(String provider, String destination,
    {bool useLegacyId = false}) {
  const anime = '42';
  const episode = 'episode/1';
  const variant = 'sub|1080p';
  return DownloadStartRequestV2(
    logicalId: logicalDownloadIdFor(
      animeId: anime, episodeKey: episode, variantKey: variant,
      providerId: useLegacyId ? null : provider,
    ),
    mediaId: anime, unitKey: episode, variantKey: variant,
    destinationPath: destination,
    sourceDescriptor: <String, Object?>{
      'providerId': provider, 'trackingUrl': episode,
      'source': 'primary', 'quality': '1080p', 'updatedAtMillis': 100,
    },
    allowPause: true, retries: 1, parallelChunks: 1,
  );
}

final class _Resolver implements DownloadSourceResolverV2 {
  _Resolver({this.offline = false});

  final bool offline;
  final providers = <String>[];
  final _counts = <String, int>{};

  @override
  Future<ResolvedDownloadSourceV2> resolve(
      Map<String, Object?> descriptor) async {
    final provider = descriptor['providerId']! as String;
    providers.add(provider);
    if (offline) throw const SocketException('offline');
    final count = _counts.update(provider, (old) => old + 1, ifAbsent: () => 1);
    final host = provider == 'com.animerift.provider' ? 'animerift' : 'native';
    return ResolvedDownloadSourceV2(url: 'https://$host.invalid/$count.mp4');
  }
}

final class _Gateway implements BackgroundDownloaderGateway {
  final started = <DownloadTaskSpecV2>[];
  final handles = <String, _Handle>{};

  @override
  Future<void> initialize() async {}

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => handles.values.toList();

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => handles[taskId];

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    started.add(spec);
    return handles[spec.taskId] = _Handle(spec.taskId);
  }

  @override
  Future<void> removeTracking(String taskId) async {}

  void expire(String taskId) => handles[taskId]!.emit(
    DownloadTransportStatus.failed, DownloadFailureCategory.sourceExpired,
  );

  Future<void> waitForStarts(int count) async {
    for (var attempt = 0; attempt < 200 && started.length < count; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(started, hasLength(count));
  }
}

final class _Handle implements DownloadTransportHandle {
  _Handle(this.taskId);

  @override
  final String taskId;
  final _events = StreamController<DownloadTransportSnapshot>.broadcast(sync: true);
  late DownloadTransportSnapshot _snapshot = DownloadTransportSnapshot(
      taskId: taskId, status: DownloadTransportStatus.running, progress: 0);

  @override
  DownloadTransportSnapshot get current => _snapshot;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _events.stream;

  void emit(DownloadTransportStatus status, [DownloadFailureCategory? failure]) {
    _snapshot = DownloadTransportSnapshot(taskId: taskId,
        status: status, progress: 0.5, failureCategory: failure);
    _events.add(_snapshot);
  }

  @override
  Future<bool> cancel() async { emit(DownloadTransportStatus.canceled); return true; }

  @override
  Future<bool> pause() async { emit(DownloadTransportStatus.paused); return true; }

  @override
  Future<bool> resume() async { emit(DownloadTransportStatus.running); return true; }
}
