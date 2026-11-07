import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:animewitcher/core/services/download_v2/anime_rift_download_metadata_v2.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_file_planner_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_integrity_verifier_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/download_launcher.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _rift = 'com.animerift.provider';
const _episode = 'https://anime-rift.com/anime/42/episode/7';
const _source =
    'https://anime-rift.com/anime/42/episode/7/source/h1/quality/1080P/download/n/7';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previousPaths;

  setUp(() async {
    AnimeRiftLocalAccountScope.reset();
    root = await Directory.systemTemp.createTemp('rift-account-downloads-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDown(() async {
    AnimeRiftLocalAccountScope.reset();
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  test(
    'guest IDs/paths remain original; account A and B get isolated IDs/paths',
    () async {
      final item = MultimediaItem(
        title: 'Series',
        url: _episode,
        posterUrl: '',
      );
      DownloadLogicalId id() => logicalDownloadIdFor(
        animeId: 'https://anime-rift.com/anime/42',
        episodeKey: _episode,
        variantKey: 'sub|1080p',
        providerId: _rift,
      );
      Future<String> path() => downloadDestinationPathV2(
        item,
        filename: 'episode.mp4',
        providerId: _rift,
        logicalId: id(),
      );

      final guestId = id();
      final guestPath = await path();
      expect(guestPath, isNot(contains('.accounts')));

      AnimeRiftLocalAccountScope.activate('account-A');
      final aHash = AnimeRiftLocalAccountScope.accountHash!;
      final aId = id();
      final aPath = await path();
      expect(aPath, contains(p.join('.accounts', aHash)));
      final aDescriptor = _descriptor();
      expect(aDescriptor['accountHash'], aHash);
      expect(downloadBelongsToCurrentRiftAccountV2(aDescriptor), isTrue);

      AnimeRiftLocalAccountScope.activate('account-B');
      final bId = id();
      final bPath = await path();
      expect(bId, isNot(aId));
      expect(bPath, isNot(aPath));
      expect(bPath, isNot(guestPath));
      expect(bId, isNot(guestId));
      expect(downloadBelongsToCurrentRiftAccountV2(aDescriptor), isFalse);

      AnimeRiftLocalAccountScope.activate('account-A');
      expect(id(), aId);
      expect(await path(), aPath);
      AnimeRiftLocalAccountScope.reset();
      expect(id(), guestId);
      expect(await path(), guestPath);
    },
  );

  test('Rift scope survives safe descriptor serialization; forged scope is dropped', () {
    AnimeRiftLocalAccountScope.activate('account-A');
    final account = AnimeRiftLocalAccountScope.accountHash!;
    final serialized = DownloadUrlRefreshDescriptor(
      trackingUrl: _episode,
      providerId: _rift,
      source: 'CR2',
      quality: '1080P',
      refreshUrl: _source,
      accountHash: account,
      updatedAtMillis: 1,
    ).toJson();
    expect(serialized['accountHash'], account);
    expect(
      DownloadUrlRefreshDescriptor.fromJson(serialized)?.accountHash,
      account,
    );
    expect(
      safeDownloadSourceDescriptorV2({
        ...serialized,
        'accountHash': '../account-B',
      }).containsKey('accountHash'),
      isFalse,
    );
  });

  test(
    'foreign and legacy guest records cannot be resumed, deleted, or restarted',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _Gateway();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: _Resolver(),
        maxConcurrentDownloads: () => 3,
      );
      addTearDown(manager.dispose);

      final guest = _request('guest', root.path);
      await manager.start(guest);
      AnimeRiftLocalAccountScope.activate('account-A');
      final a = _request('same-episode', root.path);
      await manager.start(a);
      expect(a.logicalId, isNot(guest.logicalId));
      expect(
        (await store.get(guest.logicalId))?.destinationPath,
        guest.destinationPath,
      );

      AnimeRiftLocalAccountScope.activate('account-B');
      await manager.suspendForeignRiftTransfers();
      expect(gateway.handles[a.logicalId]!.pauseCalls, 1);
      expect(gateway.handles[guest.logicalId]!.pauseCalls, 1);
      expect((await manager.records.first), isEmpty);
      expect(manager.snapshotFor(a.logicalId), isNull);
      for (final command in [
        () => manager.resume(a.logicalId),
        () => manager.retry(a.logicalId),
        () => manager.restart(a.logicalId),
        () => manager.pause(a.logicalId),
        () => manager.delete(a.logicalId),
        () => manager.cancel(a.logicalId),
      ]) {
        await expectLater(command(), throwsA(isA<StateError>()));
      }
      expect(await store.get(a.logicalId), isNotNull);
      expect(await store.get(guest.logicalId), isNotNull);
      expect(gateway.handles[a.logicalId]!.cancelCalls, 0);

      final b = _request('same-episode', root.path);
      expect(b.logicalId, isNot(a.logicalId));
      await manager.start(b);
      expect((await manager.records.first).map((row) => row.logicalId), [
        b.logicalId,
      ]);
      AnimeRiftLocalAccountScope.activate('account-A');
      expect(
        existingRiftDownloadForItemV2(
          await store.all(),
          item: MultimediaItem(
            title: 'Series',
            url: 'https://anime-rift.com/anime/42',
            provider: _rift,
            posterUrl: '',
          ),
          unitKey: _episode,
          variantKey: 'sub|1080p',
        )?.logicalId,
        a.logicalId,
      );
      expect(
        existingBatchEpisodeKeysForProviderV2(
          await store.all(),
          mediaId: 'https://anime-rift.com/anime/42',
          providerId: _rift,
        ),
        {_episode},
      );
    },
  );

  test(
    'restart suspends native foreign writer but keeps original user data',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _Gateway();
      AnimeRiftLocalAccountScope.activate('account-A');
      final a = _request('same-episode', root.path);
      final first = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: _Resolver(),
      );
      await first.start(a);
      await first.dispose();

      AnimeRiftLocalAccountScope.activate('account-B');
      final restarted = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: _Resolver(),
      );
      addTearDown(restarted.dispose);
      await restarted.initialize();
      expect(gateway.handles[a.logicalId]!.pauseCalls, greaterThanOrEqualTo(1));
      expect(gateway.started, hasLength(1));
      expect((await restarted.records.first), isEmpty);
      expect((await store.get(a.logicalId))?.intent, DownloadUserIntent.active);
      expect(
        (await store.get(a.logicalId))?.destinationPath,
        a.destinationPath,
      );
    },
  );

  test(
    'startup waits for restored identity before recovering guest work',
    () async {
      final guest = _request('queued-guest', root.path);
      final store = InMemoryLogicalDownloadStoreV2();
      await store.put(
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: guest.logicalId,
          mediaId: guest.mediaId,
          unitKey: guest.unitKey,
          variantKey: guest.variantKey,
          generation: 1,
          taskId: taskIdForGeneration(guest.logicalId, 1),
          intent: DownloadUserIntent.active,
          destinationPath: guest.destinationPath,
          sourceDescriptor: guest.sourceDescriptor,
          awaitingAdmission: true,
          updatedAtMillis: 1,
        ),
      );
      final gateway = _Gateway();
      final restored = Completer<void>();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: _Resolver(),
        ensureAccountReady: () async {
          await restored.future;
          AnimeRiftLocalAccountScope.activate('account-A');
        },
      );
      addTearDown(manager.dispose);

      final initializing = manager.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(gateway.initialized, isFalse);
      restored.complete();
      await initializing;
      expect(gateway.started, isEmpty);
      expect((await manager.records.first), isEmpty);
      expect((await store.get(guest.logicalId))?.awaitingAdmission, isTrue);
    },
  );

  test(
    'account switch during startup cannot resume old account transport',
    () async {
      AnimeRiftLocalAccountScope.activate('account-A');
      final a = _request('A-paused', root.path);
      final activeTaskId = taskIdForGeneration(a.logicalId, 2);
      final obsoleteTaskId = taskIdForGeneration(a.logicalId, 1);
      final store = InMemoryLogicalDownloadStoreV2();
      await store.put(
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: a.logicalId,
          mediaId: a.mediaId,
          unitKey: a.unitKey,
          variantKey: a.variantKey,
          generation: 2,
          taskId: activeTaskId,
          intent: DownloadUserIntent.active,
          destinationPath: a.destinationPath,
          sourceDescriptor: a.sourceDescriptor,
          updatedAtMillis: 1,
        ),
      );
      final gateway = _RetirementGateGateway(obsoleteTaskId);
      final activeHandle = _Handle(activeTaskId)
        .._emit(DownloadTransportStatus.paused);
      gateway.handles[a.logicalId] = activeHandle;
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: _Resolver(),
      );
      addTearDown(manager.dispose);

      final initialization = manager.initialize();
      await gateway.retirementReached.future;
      // Recovery already admitted A, but its last awaited cleanup is still
      // pending. Switching to B must fence the later native resume.
      AnimeRiftLocalAccountScope.activate('account-B');
      gateway.allowRetirement.complete();
      await initialization;

      expect(activeHandle.resumeCalls, 0);
      expect(activeHandle.current.status, DownloadTransportStatus.paused);
      expect(gateway.started, isEmpty);
      expect((await manager.records.first), isEmpty);
      expect((await store.get(a.logicalId))?.intent, DownloadUserIntent.active);
    },
  );

  test(
    'account switch during queued source resolution cannot start old task',
    () async {
      AnimeRiftLocalAccountScope.activate('account-A');
      final a = _request('A-queued', root.path);
      final store = InMemoryLogicalDownloadStoreV2();
      await store.put(
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: a.logicalId,
          mediaId: a.mediaId,
          unitKey: a.unitKey,
          variantKey: a.variantKey,
          generation: 1,
          taskId: taskIdForGeneration(a.logicalId, 1),
          intent: DownloadUserIntent.active,
          destinationPath: a.destinationPath,
          sourceDescriptor: a.sourceDescriptor,
          awaitingAdmission: true,
          updatedAtMillis: 1,
        ),
      );
      final gateway = _Gateway();
      final resolver = _BlockingResolver();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
      );
      addTearDown(manager.dispose);

      await manager.initialize();
      await resolver.sourceRequested.future.timeout(const Duration(seconds: 5));
      AnimeRiftLocalAccountScope.activate('account-B');
      resolver.releaseSource.complete();
      await manager.reconcileAdmission();

      expect(gateway.started, isEmpty);
      expect((await store.get(a.logicalId))?.awaitingAdmission, isTrue);
      expect((await manager.records.first), isEmpty);
    },
  );

  test(
    'secure-store restoration failure blocks Rift while other startup proceeds',
    () async {
      final guest = _request('guest', root.path);
      final store = InMemoryLogicalDownloadStoreV2();
      await store.put(
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: guest.logicalId,
          mediaId: guest.mediaId,
          unitKey: guest.unitKey,
          variantKey: guest.variantKey,
          generation: 1,
          taskId: taskIdForGeneration(guest.logicalId, 1),
          intent: DownloadUserIntent.active,
          destinationPath: guest.destinationPath,
          sourceDescriptor: guest.sourceDescriptor,
          awaitingAdmission: true,
          updatedAtMillis: 1,
        ),
      );
      final gateway = _Gateway();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: _Resolver(),
        ensureAccountReady: () async => throw StateError('secure store locked'),
      );
      addTearDown(manager.dispose);

      await manager.initialize();
      expect(gateway.initialized, isTrue);
      expect(gateway.started, isEmpty);
      expect(
        manager.canAccessSourceDescriptor(guest.sourceDescriptor),
        isFalse,
      );
      expect((await manager.records.first), isEmpty);
      await expectLater(manager.resume(guest.logicalId), throwsStateError);
      await expectLater(manager.start(guest), throwsStateError);
      expect(
        (await store.get(guest.logicalId))?.intent,
        DownloadUserIntent.active,
      );
      final nativeId = logicalDownloadIdFor(
        animeId: 'native-series',
        episodeKey: 'native-episode',
        variantKey: 'sub|720p',
        providerId: 'com.fares669.animewitcher.native',
      );
      final native = DownloadStartRequestV2(
        logicalId: nativeId,
        mediaId: 'native-series',
        unitKey: 'native-episode',
        variantKey: 'sub|720p',
        destinationPath: p.join(root.path, 'native.mp4'),
        sourceDescriptor: const {
          'providerId': 'com.fares669.animewitcher.native',
        },
        allowPause: true,
        retries: 1,
        parallelChunks: 1,
      );
      expect(
        (await manager.start(native)).status,
        DownloadTransportStatus.running,
      );
      expect(gateway.started, hasLength(1));
    },
  );

  test('completed download fallback never merges A and B account targets', () {
    DownloadItem item(String id, String? account) => DownloadItem(
      task: DownloadTask(
        taskId: id,
        url: 'https://invalid.test',
        filename: '$id.mp4',
      ),
      status: TaskStatus.complete,
      progress: 1,
      item: MultimediaItem(
        title: 'Series',
        url: _episode,
        posterUrl: '',
        provider: _rift,
      ),
      trackingUrl: _episode,
      timestamp: 1,
      accountHash: account,
    );
    final accountA = List.filled(64, 'a').join();
    final accountB = List.filled(64, 'b').join();
    expect(
      downloadsPointAtSameTarget(item('a', accountA), item('b', accountB)),
      isFalse,
    );
    expect(
      downloadsPointAtSameTarget(item('a', null), item('b', accountB)),
      isFalse,
    );
  });

  test(
    'stale foreign active record cannot occupy current account admission slot',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      AnimeRiftLocalAccountScope.activate('account-A');
      final a = _request('A-partial', root.path);
      await store.put(
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: a.logicalId,
          mediaId: a.mediaId,
          unitKey: a.unitKey,
          variantKey: a.variantKey,
          generation: 1,
          taskId: taskIdForGeneration(a.logicalId, 1),
          intent: DownloadUserIntent.active,
          destinationPath: a.destinationPath,
          sourceDescriptor: a.sourceDescriptor,
          updatedAtMillis: 1,
        ),
      );
      AnimeRiftLocalAccountScope.activate('account-B');
      final b = _request('B-new', root.path);
      final gateway = _Gateway();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: _Resolver(),
        maxConcurrentDownloads: () => 1,
      );
      addTearDown(manager.dispose);
      final started = await manager.start(b);
      expect(started.status, DownloadTransportStatus.running);
      expect(gateway.started, hasLength(1));
      expect((await store.get(a.logicalId))?.intent, DownloadUserIntent.active);
      expect(
        (await store.get(a.logicalId))?.destinationPath,
        a.destinationPath,
      );
    },
  );

  test('offline file lookup never exposes another account even with its logical ID', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    AnimeRiftLocalAccountScope.activate('account-A');
    final request = _request('completed', root.path);
    await File(request.destinationPath).writeAsBytes([1, 2, 3, 4]);
    await store.put(
      LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: request.logicalId,
        mediaId: request.mediaId,
        unitKey: request.unitKey,
        variantKey: request.variantKey,
        generation: 1,
        taskId: taskIdForGeneration(request.logicalId, 1),
        intent: DownloadUserIntent.active,
        destinationPath: request.destinationPath,
        sourceDescriptor: request.sourceDescriptor,
        completedAtMillis: 1,
        expectedBytes: 4,
        updatedAtMillis: 1,
      ),
    );
    final container = ProviderContainer(
      overrides: [
        logicalDownloadStoreV2Provider.overrideWithValue(store),
        downloadManagerV2Provider.overrideWithValue(
          DownloadManagerV2(
            store: store,
            gateway: _Gateway(),
            sourceResolver: _Resolver(),
          ),
        ),
        downloadIntegrityVerifierV2Provider.overrideWithValue(
          const DownloadIntegrityVerifierV2(),
        ),
      ],
    );
    addTearDown(container.dispose);
    final item = MultimediaItem(
      title: 'Series',
      url: 'https://anime-rift.com/anime/42',
      provider: _rift,
      posterUrl: '',
    );
    final episode = Episode(name: '7', url: _episode);
    final files = container.read(downloadedFilesProvider.notifier);
    final keyA = downloadedFileKey(item, episode: episode);
    expect(
      (await files.resolveFile(
        item,
        episode: episode,
        logicalId: request.logicalId.value,
      ))?.path,
      request.destinationPath,
    );
    AnimeRiftLocalAccountScope.activate('account-B');
    expect(downloadedFileKey(item, episode: episode), isNot(keyA));
    expect(await files.resolveFile(item, episode: episode), isNull);
    expect(
      await files.resolveFile(
        item,
        episode: episode,
        logicalId: request.logicalId.value,
      ),
      isNull,
    );
    AnimeRiftLocalAccountScope.reset();
    expect(await files.resolveFile(item, episode: episode), isNull);
    AnimeRiftLocalAccountScope.activate('account-A');
    expect(
      (await files.resolveFile(item, episode: episode))?.path,
      request.destinationPath,
    );
  });
}

Map<String, Object?> _descriptor() => DownloadUrlRefreshDescriptor(
  trackingUrl: _episode,
  providerId: _rift,
  source: 'CR2',
  quality: '1080P',
  refreshUrl: _source,
  accountHash: AnimeRiftLocalAccountScope.accountHash,
  updatedAtMillis: 1,
).toJson();

DownloadStartRequestV2 _request(String name, String root) {
  const mediaId = 'https://anime-rift.com/anime/42';
  const variant = 'sub|1080p';
  final logicalId = logicalDownloadIdFor(
    animeId: mediaId,
    episodeKey: _episode,
    variantKey: variant,
    providerId: _rift,
  );
  return DownloadStartRequestV2(
    logicalId: logicalId,
    mediaId: mediaId,
    unitKey: _episode,
    variantKey: variant,
    destinationPath: p.join(root, '$name-${logicalId.value}.mp4'),
    sourceDescriptor: _descriptor(),
    allowPause: true,
    retries: 2,
    parallelChunks: 1,
    expectedBytes: 100,
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getDownloadsPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Resolver implements DownloadSourceResolverV2 {
  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async => const ResolvedDownloadSourceV2(
    url: 'https://cdn.example/video.mp4',
    expectedBytes: 100,
  );
}

class _BlockingResolver extends _Resolver {
  final sourceRequested = Completer<void>();
  final releaseSource = Completer<void>();

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    if (!sourceRequested.isCompleted) sourceRequested.complete();
    await releaseSource.future;
    return super.resolve(descriptor);
  }
}

class _Gateway implements BackgroundDownloaderGateway {
  bool initialized = false;
  final started = <DownloadTaskSpecV2>[];
  final handles = <DownloadLogicalId, _Handle>{};
  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    started.add(spec);
    final id = parseDownloadTaskIdentityV2(spec.taskId)!.logicalId;
    return handles[id] = _Handle(spec.taskId);
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async =>
      handles.values.where((handle) => handle.taskId == taskId).firstOrNull;
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      handles.values.toList();
  @override
  Future<void> removeTracking(String taskId) async {}
}

class _RetirementGateGateway extends _Gateway {
  _RetirementGateGateway(this.obsoleteTaskId);

  final String obsoleteTaskId;
  final retirementReached = Completer<void>();
  final allowRetirement = Completer<void>();

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [
    ...handles.values,
    _Handle(obsoleteTaskId).._emit(DownloadTransportStatus.complete),
  ];

  @override
  Future<void> removeTracking(String taskId) async {
    if (taskId != obsoleteTaskId) return;
    if (!retirementReached.isCompleted) retirementReached.complete();
    await allowRetirement.future;
  }
}

class _Handle implements DownloadTransportHandle {
  _Handle(this.taskId);
  @override
  final String taskId;
  final controller = StreamController<DownloadTransportSnapshot>.broadcast(
    sync: true,
  );
  late DownloadTransportSnapshot _current = DownloadTransportSnapshot(
    taskId: taskId,
    status: DownloadTransportStatus.running,
    progress: 0,
  );
  int pauseCalls = 0;
  int resumeCalls = 0;
  int cancelCalls = 0;
  @override
  DownloadTransportSnapshot get current => _current;
  @override
  Stream<DownloadTransportSnapshot> get snapshots => controller.stream;
  void _emit(DownloadTransportStatus status) {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: status,
      progress: 0,
    );
    controller.add(_current);
  }

  @override
  Future<bool> pause() async {
    pauseCalls++;
    _emit(DownloadTransportStatus.paused);
    return true;
  }

  @override
  Future<bool> resume() async {
    resumeCalls++;
    _emit(DownloadTransportStatus.running);
    return true;
  }

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    _emit(DownloadTransportStatus.canceled);
    return true;
  }
}
