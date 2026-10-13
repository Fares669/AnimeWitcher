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
  for (final invalidSelected in [false, true]) {
    test('selected completed file is exact and never substituted invalid=$invalidSelected', () async {
      final root = await Directory.systemTemp.createTemp('aw-selected-file-');
      final store = InMemoryLogicalDownloadStoreV2();
      final selected = await File('${root.path}/selected.mp4').writeAsBytes([1, 2]);
      final newer = await File('${root.path}/newer.mp4').writeAsBytes([3, 4]);
      final otherUnit = await File('${root.path}/other.mp4').writeAsBytes([5, 6]);
      for (final entry in [(id: 'selected', file: selected, unit: 'episode://saved', timestamp: 1),
        (id: 'newer', file: newer, unit: 'episode://saved', timestamp: 2),
        (id: 'different-unit', file: otherUnit, unit: 'episode://different', timestamp: 3)]) {
        await store.put(LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2, logicalId: DownloadLogicalId(entry.id),
          mediaId: 'saved-show', unitKey: entry.unit, variantKey: entry.id, generation: 1,
          taskId: 'task-${entry.id}', intent: DownloadUserIntent.active, destinationPath: entry.file.path,
          sourceDescriptor: const {}, updatedAtMillis: entry.timestamp, completedAtMillis: 1, expectedBytes: 2,
        ));
      }
      final manager = DownloadManagerV2(store: store, gateway: _Gateway(), sourceResolver: StaticSourceResolverV2());
      final container = ProviderContainer(overrides: [downloadManagerV2Provider.overrideWithValue(manager)]);
      try {
        // Startup owns repair of invalid completed artifacts. Mutate only after
        // recovery to exercise the resolver's live validation without repair.
        await manager.initialize();
        if (invalidSelected) await selected.writeAsBytes([1]);
        final files = container.read(downloadedFilesProvider.notifier);
        final item = MultimediaItem(title: 'Saved show', url: 'show://saved', posterUrl: '');
        final episode = Episode(name: 'Saved', url: 'episode://saved', episode: 1);
        expect((await files.resolveFile(item, episode: episode, logicalId: 'selected'))?.path,
          invalidSelected ? isNull : selected.path);
        expect((await files.resolveFile(item, episode: episode, logicalId: 'newer'))?.path, newer.path);
        expect(await files.resolveFile(item, episode: episode, logicalId: 'different-unit'), isNull);
        expect(await files.resolveFile(item, episode: episode, logicalId: 'unknown'), isNull);
        expect((await files.resolveFile(item, episode: episode))?.path, newer.path);
        expect(await newer.readAsBytes(), [3, 4]);
        expect(await selected.exists(), isTrue);
      } finally {
        container.dispose();
        await manager.dispose();
        await root.delete(recursive: true);
      }
    });
  }
}

class _Gateway implements BackgroundDownloaderGateway {
  @override
  Future<void> initialize() async {}
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => const [];
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async => throw StateError('completed only');
  @override
  Future<void> removeTracking(String taskId) async {}
}
