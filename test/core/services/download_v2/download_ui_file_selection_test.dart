import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/features/details/presentation/downloaded_file_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_v2_test_support.dart';

void main() {
  test(
    'offline Rift file lookup recognizes canonical episode aliases',
    () async {
      final root = await Directory.systemTemp.createTemp('aw-rift-alias-file-');
      final file = await File('${root.path}/rift.mp4').writeAsBytes([1]);
      final store = InMemoryLogicalDownloadStoreV2();
      await store.put(
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: const DownloadLogicalId('rift-alias'),
          mediaId: 'https://anime-rift.com/anime/42',
          unitKey: 'https://anime-rift.com/episode/7',
          variantKey: 'sub',
          generation: 1,
          taskId: 'task-rift-alias',
          intent: DownloadUserIntent.active,
          destinationPath: file.path,
          sourceDescriptor: const {'providerId': 'com.animerift.provider'},
          updatedAtMillis: 1,
          completedAtMillis: 1,
          expectedBytes: 1,
        ),
      );
      final container = ProviderContainer(
        overrides: [logicalDownloadStoreV2Provider.overrideWithValue(store)],
      );
      try {
        final files = container.read(downloadedFilesProvider.notifier);
        final item = MultimediaItem(
          title: 'Rift',
          url: 'https://anime-rift.com/anime/42',
          posterUrl: '',
          provider: 'com.animerift.provider',
        );
        final episode = Episode(
          name: '7',
          url: 'https://www.anime-rift.com/episode/7?token=rotated#fragment',
        );

        expect(
          (await files.resolveFile(item, episode: episode))?.path,
          file.path,
        );
        expect(
          (await files.resolveFileForTrackingUrl(
            episode.url,
            item: item,
            episode: episode,
          ))?.path,
          file.path,
        );
      } finally {
        container.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test('offline file lookup isolates records sharing an episode URL', () async {
    final root = await Directory.systemTemp.createTemp('aw-source-files-');
    final native = await File('${root.path}/native.mp4').writeAsBytes([1]);
    final rift = await File('${root.path}/rift.mp4').writeAsBytes([2]);
    final store = InMemoryLogicalDownloadStoreV2();
    for (final entry in [
      (
        id: 'native',
        file: native,
        provider: 'com.fares669.animewitcher.native',
        stamp: 1,
      ),
      (id: 'rift', file: rift, provider: 'animerift', stamp: 2),
    ]) {
      await store.put(
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: DownloadLogicalId(entry.id),
          mediaId: 'same',
          unitKey: 'episode://same',
          variantKey: 'sub',
          generation: 1,
          taskId: 'task-${entry.id}',
          intent: DownloadUserIntent.active,
          destinationPath: entry.file.path,
          sourceDescriptor: {'providerId': entry.provider},
          updatedAtMillis: entry.stamp,
          completedAtMillis: 1,
          expectedBytes: 1,
        ),
      );
    }
    final container = ProviderContainer(
      overrides: [logicalDownloadStoreV2Provider.overrideWithValue(store)],
    );
    try {
      final files = container.read(downloadedFilesProvider.notifier);
      final episode = Episode(name: 'one', url: 'episode://same');
      final nativeItem = MultimediaItem(
        title: 'x',
        url: '/same',
        posterUrl: '',
      );
      final riftItem = nativeItem.copyWith(provider: 'animerift');
      expect(
        (await files.resolveFile(nativeItem, episode: episode))?.path,
        native.path,
      );
      expect(
        (await files.resolveFile(riftItem, episode: episode))?.path,
        rift.path,
      );
      expect(
        (await files.resolveFile(
          nativeItem,
          episode: episode,
          logicalId: 'rift',
        ))?.path,
        rift.path,
      );
      await files.checkFile(nativeItem, episode: episode);
      await files.checkFile(riftItem, episode: episode);
      final cached = container.read(downloadedFilesProvider);
      expect(
        cached[downloadedFileKey(nativeItem, episode: episode)]?.path,
        native.path,
      );
      expect(
        cached[downloadedFileKey(riftItem, episode: episode)]?.path,
        rift.path,
      );
    } finally {
      container.dispose();
      await root.delete(recursive: true);
    }
  });

  for (final invalidSelected in [false, true]) {
    test(
      'selected completed file is exact and never substituted invalid=$invalidSelected',
      () async {
        final root = await Directory.systemTemp.createTemp('aw-selected-file-');
        final store = InMemoryLogicalDownloadStoreV2();
        final selected = await File('${root.path}/selected.mp4')
            .writeAsBytes([1, 2]);
        final newer = await File('${root.path}/newer.mp4').writeAsBytes([3, 4]);
        final otherUnit = await File('${root.path}/other.mp4')
            .writeAsBytes([5, 6]);
        for (final entry in [
          (
            id: 'selected',
            file: selected,
            unit: 'episode://saved',
            timestamp: 1,
          ),
          (id: 'newer', file: newer, unit: 'episode://saved', timestamp: 2),
          (
            id: 'different-unit',
            file: otherUnit,
            unit: 'episode://different',
            timestamp: 3,
          ),
        ]) {
          await store.put(
            LogicalDownloadRecordV2(
              schemaVersion: kLogicalDownloadSchemaVersionV2,
              logicalId: DownloadLogicalId(entry.id),
              mediaId: 'saved-show',
              unitKey: entry.unit,
              variantKey: entry.id,
              generation: 1,
              taskId: 'task-${entry.id}',
              intent: DownloadUserIntent.active,
              destinationPath: entry.file.path,
              sourceDescriptor: const {},
              updatedAtMillis: entry.timestamp,
              completedAtMillis: 1,
              expectedBytes: 2,
            ),
          );
        }
        final manager = DownloadManagerV2(
          store: store,
          gateway: _Gateway(),
          sourceResolver: StaticSourceResolverV2(),
        );
        final container = ProviderContainer(
          overrides: [
            downloadManagerV2Provider.overrideWithValue(manager),
            logicalDownloadStoreV2Provider.overrideWithValue(store),
          ],
        );
        try {
          // Startup owns repair of invalid completed artifacts. Mutate only after
          // recovery to exercise the resolver's live validation without repair.
          await manager.initialize();
          if (invalidSelected) await selected.writeAsBytes([1]);
          final files = container.read(downloadedFilesProvider.notifier);
          final item = MultimediaItem(
            title: 'Saved show',
            url: 'show://saved',
            posterUrl: '',
          );
          final episode = Episode(
            name: 'Saved',
            url: 'episode://saved',
            episode: 1,
          );
          expect(
            (await files.resolveFile(
              item,
              episode: episode,
              logicalId: 'selected',
            ))?.path,
            invalidSelected ? isNull : selected.path,
          );
          expect(
            (await files.resolveFile(
              item,
              episode: episode,
              logicalId: 'newer',
            ))?.path,
            newer.path,
          );
          expect(
            await files.resolveFile(
              item,
              episode: episode,
              logicalId: 'different-unit',
            ),
            isNull,
          );
          expect(
            await files.resolveFile(
              item,
              episode: episode,
              logicalId: 'unknown',
            ),
            isNull,
          );
          expect(
            (await files.resolveFile(item, episode: episode))?.path,
            newer.path,
          );
          expect(await newer.readAsBytes(), [3, 4]);
          expect(await selected.exists(), isTrue);
        } finally {
          container.dispose();
          await manager.dispose();
          await root.delete(recursive: true);
        }
      },
    );
  }

  test(
    'completed video resolves from disk while transport initialization is hung',
    () async {
      final root = await Directory.systemTemp.createTemp('aw-offline-file-');
      final file = await File('${root.path}/saved.mp4').writeAsBytes([1, 2]);
      final store = InMemoryLogicalDownloadStoreV2();
      const logicalId = DownloadLogicalId('offline-selected');
      await store.put(
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: logicalId,
          mediaId: 'saved-show',
          unitKey: 'episode://saved',
          variantKey: 'original',
          generation: 1,
          taskId: 'task-offline',
          intent: DownloadUserIntent.active,
          destinationPath: file.path,
          sourceDescriptor: const {},
          updatedAtMillis: 1,
          completedAtMillis: 1,
          expectedBytes: 2,
        ),
      );
      final pending = Completer<void>();
      final gateway = _Gateway(pendingInitialization: pending);
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: StaticSourceResolverV2(),
      );
      var initialized = false;
      final initialization = manager.initialize().then(
        (_) => initialized = true,
      );
      final container = ProviderContainer(
        overrides: [
          downloadManagerV2Provider.overrideWithValue(manager),
          logicalDownloadStoreV2Provider.overrideWithValue(store),
        ],
      );
      try {
        expect(gateway.initializationCalls, 1);
        final files = container.read(downloadedFilesProvider.notifier);
        final item = MultimediaItem(
          title: 'Saved show',
          url: 'show://saved',
          posterUrl: '',
        );
        final episode = Episode(
          name: 'Saved',
          url: 'episode://saved',
          episode: 1,
        );
        final result = await files
            .resolveFile(item, episode: episode, logicalId: logicalId.value)
            .timeout(const Duration(seconds: 1));
        expect(result?.path, file.path);
        expect(initialized, isFalse);
        expect(await file.readAsBytes(), [1, 2]);
        // The offline resolver must retain live integrity checks, not trust the
        // completed timestamp or substitute another variant after corruption.
        await file.writeAsBytes([1]);
        expect(
          await files
              .resolveFile(item, episode: episode, logicalId: logicalId.value)
              .timeout(const Duration(seconds: 1)),
          isNull,
        );
        expect(initialized, isFalse);
      } finally {
        pending.complete();
        await initialization;
        container.dispose();
        await manager.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}

class _Gateway implements BackgroundDownloaderGateway {
  _Gateway({this.pendingInitialization});
  final Completer<void>? pendingInitialization;
  int initializationCalls = 0;
  @override
  Future<void> initialize() async {
    initializationCalls++;
    await pendingInitialization?.future;
  }

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => const [];
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError('completed only');
  @override
  Future<void> removeTracking(String taskId) async {}
}
