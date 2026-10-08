import 'dart:async';
import 'dart:io';

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
import 'package:background_downloader/background_downloader.dart' show TaskStatus;
import 'package:flutter_test/flutter_test.dart';

final class _EmptyDownloadsNotifier extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const <DownloadItem>[];
}

void main() {
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

  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async =>
      Map<String, Map<String, dynamic>>.from(metadata);

  @override
  Future<void> removeDownloadMetadata(String taskId) async {
    metadata.remove(taskId);
  }
}

final class _ReaddGateway implements BackgroundDownloaderGateway {
  final Map<String, _ReaddHandle> handles = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    final handle = _ReaddHandle(spec.taskId);
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
  _ReaddHandle(this.taskId);

  @override
  final String taskId;

  @override
  DownloadTransportSnapshot get current => DownloadTransportSnapshot(
    taskId: taskId,
    status: DownloadTransportStatus.running,
    progress: 0,
  );

  @override
  Stream<DownloadTransportSnapshot> get snapshots => const Stream.empty();

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async => true;
}
