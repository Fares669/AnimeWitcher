import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/services/download_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    DownloadService.configureHoldingQueueForTesting = null;
  });

  test(
    'applyQueueSettings writes storage and reconfigures the holding queue',
    () async {
      final storage = MemoryStorageService();
      List<(String, dynamic)>? configured;
      DownloadService.configureHoldingQueueForTesting = (globalConfig) async {
        configured = globalConfig;
      };

      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          dioClientProvider.overrideWithValue(Dio()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(downloadServiceProvider)
          .applyQueueSettings(maxConcurrent: 3);

      expect(storage.getDownloadConcurrency(), 3);
      expect(configured, <(String, dynamic)>[(Config.holdingQueue, false)]);
    },
  );

  test('applyQueueSettings clamps before writing and configuring', () async {
    final storage = MemoryStorageService();
    List<(String, dynamic)>? configured;
    DownloadService.configureHoldingQueueForTesting = (globalConfig) async {
      configured = globalConfig;
    };

    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        dioClientProvider.overrideWithValue(Dio()),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(downloadServiceProvider)
        .applyQueueSettings(maxConcurrent: 0);

    expect(storage.getDownloadConcurrency(), 1);
    expect(configured!.single.$2, false);
  });
}
