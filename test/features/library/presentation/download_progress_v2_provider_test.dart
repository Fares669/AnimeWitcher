import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';

import '../../../core/services/download_v2/download_v2_test_support.dart';
import '../../../support/memory_storage_service.dart';

import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    final container = ProviderContainer(
      overrides: [
        downloadManagerV2Provider.overrideWithValue(manager),
        logicalDownloadStoreV2Provider.overrideWithValue(store),
        storageServiceProvider.overrideWithValue(_IdleStorage()),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await manager.dispose();
    });
    var publications = 0;
    container.listen(downloadsProvider, (_, next) {
      if (next.hasValue) publications++;
    });
    await container.read(downloadsProvider.future);
    await tester.pump();
    final afterBuild = publications;

    await tester.pump(const Duration(seconds: 3));

    expect(publications, afterBuild);
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
  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async =>
      const {};
}
