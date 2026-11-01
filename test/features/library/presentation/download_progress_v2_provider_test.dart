import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';

import '../../../core/services/download_v2/download_v2_test_support.dart';
import '../../../support/memory_storage_service.dart';

import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:background_downloader/background_downloader.dart' show TaskStatus, DownloadTask;
import 'package:flutter_test/flutter_test.dart';

final class _EmptyDownloadsNotifier extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const <DownloadItem>[];
}

void main() {
  for (final scenario in [([0], true), ([1, 2], true), ([0, 1, 2], true), ([0], false)]) {
    final selection = scenario.$1;
    final accepted = scenario.$2;
    test('deletion hides $selection before native cancellation finishes (accepted: $accepted)', () async {
      final temp = await Directory.systemTemp.createTemp('aw-immediate-delete-');
      final gate = Completer<void>();
      final store = InMemoryLogicalDownloadStoreV2();
      final storage = _DownloadMetadataStorage();
      final gateway = _ReaddGateway(cancelGate: gate.future, cancelAccepted: accepted);
      final manager = DownloadManagerV2(store: store, gateway: gateway,
        sourceResolver: StaticSourceResolverV2());
      final container = ProviderContainer(overrides: [
        downloadManagerV2Provider.overrideWithValue(manager),
        logicalDownloadStoreV2Provider.overrideWithValue(store),
        storageServiceProvider.overrideWithValue(storage),
      ]);
      final subscription = container.listen(downloadsProvider, (_, _) {});
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        subscription.close(); container.dispose(); await manager.dispose();
        await temp.delete(recursive: true);
      });
      await container.read(downloadsProvider.future);
      for (var i = 0; i < 3; i++) {
        final id = DownloadLogicalId('immediate-$i');
        storage.metadata[id.value] = {'logicalId': id.value, 'timestamp': i + 1,
          'item': MultimediaItem(title: 'Episode $i', url: 'anime://test', posterUrl: '').toJson()};
        await manager.start(DownloadStartRequestV2(logicalId: id, mediaId: 'anime',
          unitKey: '$i', variantKey: 'original', destinationPath: '${temp.path}/$i.mp4',
          sourceDescriptor: const {}, allowPause: true, retries: 0, parallelChunks: 1));
      }
      await _waitForDownloadCount(container, 3);
      final items = container.read(downloadsProvider).requireValue;
      final removal = container.read(downloadsProvider.notifier)
          .removeDownloads([for (final i in selection) items[i]]);
      final outcome = removal.then<Object>((value) => value, onError: (Object error) => error);
      expect(container.read(downloadsProvider).requireValue, hasLength(3 - selection.length));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(container.read(downloadsProvider).requireValue, hasLength(3 - selection.length),
        reason: 'native progress and record updates must not resurrect pending removals');
      gate.complete();
      expect(await outcome, accepted ? isTrue : isA<StateError>());
      await _waitForDownloadCount(container, accepted ? 3 - selection.length : 3);
    });
  }

  testWidgets('idle downloads do not publish a new list every second', (
    tester,
  ) async {
    final store = InMemoryLogicalDownloadStoreV2();
    final manager = DownloadManagerV2(
      store: store,
      gateway: _EmptyGateway(),
      sourceResolver: StaticSourceResolverV2(),
    );
    final storage = _IdleStorage();
    final container = ProviderContainer(
      overrides: [
        downloadManagerV2Provider.overrideWithValue(manager),
        logicalDownloadStoreV2Provider.overrideWithValue(store),
        storageServiceProvider.overrideWithValue(storage),
      ],
    );
    try {
      var publications = 0;
      container.listen(downloadsProvider, (_, next) {
        if (next.hasValue) publications++;
      });
      await container.read(downloadsProvider.future);
      await tester.pump();
      final afterBuild = publications;
      final metadataReadsAfterBuild = storage.metadataReads;

      await tester.pump(const Duration(seconds: 31));

      expect(publications, afterBuild);
      expect(storage.metadataReads, metadataReadsAfterBuild);
    } finally {
      // testWidgets checks for pending timers before addTearDown callbacks run.
      // Dispose the keepAlive provider here so its periodic timers are canceled.
      container.dispose();
      await manager.dispose();
    }
  });

  test('refused legacy deletion keeps its metadata and reports failure', () async {
    final temp = await Directory.systemTemp.createTemp('aw-legacy-owner-');
    final file = File('${temp.path}/episode.mp4');
    await file.writeAsBytes([1, 2, 3]);
    final store = InMemoryLogicalDownloadStoreV2();
    final id = logicalDownloadIdFor(animeId: 'a1', episodeKey: '1', variantKey: 'original');
    await store.put(LogicalDownloadRecordV2(schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: id, mediaId: 'a1', unitKey: '1', variantKey: 'original', generation: 1,
      taskId: taskIdForGeneration(id, 1), intent: DownloadUserIntent.paused,
      destinationPath: file.path, sourceDescriptor: const {}, updatedAtMillis: 1));
    final media = MultimediaItem(title: 'Example', url: '/anime', posterUrl: '');
    final storage = _DownloadMetadataStorage();
    storage.metadata['legacy-row'] = {'item': media.toJson(), 'filePath': file.path, 'timestamp': 1};
    final manager = DownloadManagerV2(store: store, gateway: _EmptyGateway(), sourceResolver: StaticSourceResolverV2());
    final container = ProviderContainer(overrides: [
      downloadManagerV2Provider.overrideWithValue(manager), logicalDownloadStoreV2Provider.overrideWithValue(store),
      storageServiceProvider.overrideWithValue(storage),
    ]);
    final subscription = container.listen(downloadsProvider, (_, __) {});
    addTearDown(() async {
      subscription.close(); container.dispose(); await manager.dispose(); await temp.delete(recursive: true);
    });
    await container.read(downloadsProvider.future);
    final legacy = DownloadItem(task: DownloadTask(url: 'https://cdn.test/episode.mp4', taskId: 'legacy-row'),
      status: TaskStatus.complete, progress: 1, item: media, timestamp: 1, destinationPath: file.path);
    final removed = await container.read(downloadsProvider.notifier).removeDownloads([legacy]);
    expect(removed, isFalse);
    expect(storage.metadata.containsKey('legacy-row'), isTrue);
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect((await store.get(id))!.intent, DownloadUserIntent.paused);
    await expectLater(
      container.read(downloadsProvider.notifier).removeDownload(legacy),
      throwsStateError,
    );
  });

  test('a re-downloaded episode is visible without rebuilding the downloads provider', () async {
    final temp = await Directory.systemTemp.createTemp('aw-v2-readd-');
    final store = InMemoryLogicalDownloadStoreV2();
    final storage = _DownloadMetadataStorage();
    final gateway = _ReaddGateway();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: StaticSourceResolverV2(),
    );
    final container = ProviderContainer(
      overrides: [
        downloadManagerV2Provider.overrideWithValue(manager),
        logicalDownloadStoreV2Provider.overrideWithValue(store),
        storageServiceProvider.overrideWithValue(storage),
      ],
    );
    final subscription = container.listen(downloadsProvider, (_, __) {});
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await manager.dispose();
      await temp.delete(recursive: true);
    });

    await container.read(downloadsProvider.future);
    final logicalId = logicalDownloadIdFor(
      animeId: 'anilist:101',
      episodeKey: '1',
      variantKey: 'sub:480p',
    );
    final request = DownloadStartRequestV2(
      logicalId: logicalId,
      mediaId: 'anilist:101',
      unitKey: '1',
      variantKey: 'sub:480p',
      destinationPath: '${temp.path}/episode.mp4',
      sourceDescriptor: const <String, Object?>{'providerId': 'provider.example'},
      allowPause: true,
      retries: 2,
      parallelChunks: 1,
    );
    final media = MultimediaItem(
      title: 'Episode 1',
      url: 'https://animewitcher.test/101',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
    );

    storage.metadata[logicalId.value] = <String, dynamic>{
      'logicalId': logicalId.value,
      'item': media.toJson(),
      'timestamp': 1,
    };
    final first = await manager.start(request);
    await _waitForDownloadCount(container, 1);
    final previous = container.read(downloadsProvider).requireValue.single;
    expect(previous.id, first.taskId);

    await container.read(downloadsProvider.notifier).removeDownload(previous);
    await _waitForDownloadCount(container, 0);
    expect(storage.metadata, isEmpty);

    // A fresh start for the same logical episode uses the original g1 taskId.
    storage.metadata[logicalId.value] = <String, dynamic>{
      'logicalId': logicalId.value,
      'item': media.toJson(),
      'timestamp': 2,
    };
    final second = await manager.start(request);
    expect(second.taskId, first.taskId);
    await _waitForDownloadCount(container, 1);
    final visible = container.read(downloadsProvider).requireValue.single;
    expect(visible.id, second.taskId);
    expect(visible.status, isNot(TaskStatus.canceled));
  });

  test('does not construct the V2 manager for an empty projection', () {
    final container = ProviderContainer(
      overrides: [
        downloadsProvider.overrideWith(() => _EmptyDownloadsNotifier()),
        downloadManagerV2Provider.overrideWith((ref) {
          throw StateError(
            'V2 manager must not be read for an empty projection',
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(downloadProgressProvider), isEmpty);
  });

  test('deletion cannot erase replacement metadata after the logical queue releases', () async {
    final temp = await Directory.systemTemp.createTemp('aw-v2-delete-readd-');
    final store = InMemoryLogicalDownloadStoreV2();
    final storage = _DownloadMetadataStorage();
    final manager = DownloadManagerV2(
      store: store,
      gateway: _ReaddGateway(),
      sourceResolver: StaticSourceResolverV2(),
    );
    final container = ProviderContainer(overrides: [
      downloadManagerV2Provider.overrideWithValue(manager),
      logicalDownloadStoreV2Provider.overrideWithValue(store),
      storageServiceProvider.overrideWithValue(storage),
    ]);
    final subscription = container.listen(downloadsProvider, (_, __) {});
    addTearDown(() async {
      subscription.close();
      container.dispose();
      await manager.dispose();
      await temp.delete(recursive: true);
    });
    await container.read(downloadsProvider.future);
    final logicalId = logicalDownloadIdFor(animeId: 'delete-readd', episodeKey: '1', variantKey: 'original');
    final request = DownloadStartRequestV2(
      logicalId: logicalId,
      mediaId: 'delete-readd',
      unitKey: '1',
      variantKey: 'original',
      destinationPath: '${temp.path}/episode.mp4',
      sourceDescriptor: const {},
      allowPause: true,
      retries: 0,
      parallelChunks: 1,
    );
    final media = MultimediaItem(title: 'Replacement', url: '/delete-readd', posterUrl: '');
    Map<String, dynamic> metadata(int timestamp) => {
      'logicalId': logicalId.value,
      'item': media.toJson(),
      'timestamp': timestamp,
    };
    storage.metadata[logicalId.value] = metadata(1);
    await manager.start(request);
    await _waitForDownloadCount(container, 1);
    final previous = container.read(downloadsProvider).requireValue.single;

    Future<void>? replacement;
    storage.beforeRead = () async {
      if (replacement != null) return replacement;
      if (await store.get(logicalId) != null) return;
      // The launcher saves fresh metadata after start returns. Both occur
      // after manager.delete releases its queue, before the UI cleanup read.
      replacement = () async {
        await manager.start(request);
        storage.metadata[logicalId.value] = metadata(2);
      }();
      await replacement;
    };
    await container.read(downloadsProvider.notifier).removeDownload(previous);
    await replacement;

    expect(await store.get(logicalId), isNotNull);
    expect(storage.metadata[logicalId.value]?['timestamp'], 2);
    await _waitForDownloadCount(container, 1);
  });
}

final class _EmptyGateway implements BackgroundDownloaderGateway {
  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError('idle test must not start downloads');

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => const [];

  @override
  Future<void> removeTracking(String taskId) async {}
}

final class _IdleStorage extends MemoryStorageService {
  int metadataReads = 0;

  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async {
    metadataReads++;
    return const {};
  }
}

Future<void> _waitForDownloadCount(ProviderContainer container, int expected) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if ((container.read(downloadsProvider).value?.length ?? -1) == expected) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Expected $expected visible downloads; got ${container.read(downloadsProvider).value?.length}');
}

final class _DownloadMetadataStorage extends MemoryStorageService {
  final Map<String, Map<String, dynamic>> metadata = {};
  Future<void> Function()? beforeRead;

  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async {
    await beforeRead?.call();
    return Map<String, Map<String, dynamic>>.from(metadata);
  }

  @override
  Future<void> removeDownloadMetadata(String taskId) async {
    metadata.remove(taskId);
  }

  @override
  Future<bool> removeDownloadMetadataIfUnchanged(String taskId, Map<String, dynamic> expected) async {
    if (!const DeepCollectionEquality().equals(metadata[taskId], expected)) return false;
    metadata.remove(taskId);
    return true;
  }
}

final class _ReaddGateway implements BackgroundDownloaderGateway {
  _ReaddGateway({this.cancelGate, this.cancelAccepted = true});
  final Future<void>? cancelGate;
  final bool cancelAccepted;
  final Map<String, _ReaddHandle> handles = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    final handle = _ReaddHandle(spec.taskId, cancelGate: cancelGate, cancelAccepted: cancelAccepted);
    handles[spec.taskId] = handle;
    return handle;
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => handles[taskId];

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => handles.values.toList();

  @override
  Future<void> removeTracking(String taskId) async {
    handles.remove(taskId);
  }
}

final class _ReaddHandle implements DownloadTransportHandle {
  _ReaddHandle(this.taskId, {this.cancelGate, this.cancelAccepted = true}) : _current = DownloadTransportSnapshot(
    taskId: taskId,
    status: DownloadTransportStatus.running,
    progress: 0,
  );

  @override
  final String taskId;

  final Future<void>? cancelGate;
  final bool cancelAccepted;
  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _changes =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _changes.stream;

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async {
    if (cancelGate != null) await cancelGate;
    if (!cancelAccepted) return false;
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.canceled,
      progress: 0,
    );
    _changes.add(_current);
    return true;
  }
}
