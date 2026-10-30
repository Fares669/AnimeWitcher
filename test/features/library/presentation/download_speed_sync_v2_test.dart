import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_continued_processing_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../core/services/download_v2/download_v2_test_support.dart';
import '../../../support/memory_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('app strip and iOS receive the same total speed sample without another timer', () async {
    const channel = MethodChannel(
      'com.animewitcher.app/download_continued_processing',
    );
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    final id = logicalDownloadIdFor(
      animeId: 'sync',
      episodeKey: '1',
      variantKey: 'sub',
    );
    final record = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: id,
      mediaId: 'sync',
      unitKey: '1',
      variantKey: 'sub',
      generation: 1,
      taskId: taskIdForGeneration(id, 1),
      intent: DownloadUserIntent.active,
      destinationPath: 'downloads/speed-sync.mp4',
      sourceDescriptor: const {'providerId': 'test'},
      expectedBytes: 10000000,
      updatedAtMillis: 1,
    );
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(record);
    final handle = _Handle(record.taskId);
    final observer = IosDownloadContinuedProcessingObserverV2(
      forceAvailableForTesting: true,
    );
    final manager = DownloadManagerV2(
      store: store,
      gateway: _Gateway(handle),
      sourceResolver: StaticSourceResolverV2(),
      presentationObservers: [observer],
    );
    final storage = _Storage(id.value);
    final container = ProviderContainer(
      overrides: [
        downloadManagerV2Provider.overrideWithValue(manager),
        logicalDownloadStoreV2Provider.overrideWithValue(store),
        storageServiceProvider.overrideWithValue(storage),
      ],
    );
    ProviderSubscription<AsyncValue<List<DownloadItem>>>? subscription;
    try {
      await manager.initialize();
      subscription = container.listen(downloadsProvider, (_, _) {});
      await container.read(downloadsProvider.future);
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(calls.where((call) => call.method == 'start'), isNotEmpty);
      final metadataReads = storage.metadataReads;
      calls.clear();

      for (final bytesPerSecond in <double>[2000000, 0, 3000000]) {
        calls.clear();
        manager.observeNativeNetworkSpeed(
          taskId: record.taskId,
          bytesPerSecond: bytesPerSecond,
        );
        final speedMBps = bytesPerSecond / 1000000;
        expect(manager.snapshotFor(id)!.networkSpeedMBps, speedMBps);
        // Drain platform calls, including zero-speed and recovery transitions.
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          downloadSessionSummaryNotifier.value.totalSpeedBytesPerSecond,
          bytesPerSecond,
          reason:
              'the in-app strip must publish the same session total immediately',
        );
        expect(
          calls
              .where((call) => call.method == 'update')
              .last
              .arguments['speedBytesPerSecond'],
          bytesPerSecond,
          reason:
              'iOS must use this sample without its own second sampling timer',
        );
      }
      expect(
        storage.metadataReads,
        metadataReads,
        reason: 'speed-only updates must stay in memory',
      );
      calls.clear();
      final currentList = container.read(downloadsProvider).requireValue;
      manager.observeNativeNetworkSpeed(
        taskId: taskIdForGeneration(id, 2),
        bytesPerSecond: 9000000,
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(downloadsProvider).requireValue, same(currentList));
      expect(
        calls,
        isEmpty,
        reason: 'a non-current generation cannot update either presentation',
      );
    } finally {
      subscription?.close();
      container.dispose();
      await manager.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
}

final class _Storage extends MemoryStorageService {
  _Storage(this.logicalId);
  final String logicalId;
  int metadataReads = 0;
  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async {
    metadataReads++;
    return {
      logicalId: {
        'logicalId': logicalId,
        'item': MultimediaItem(
          title: 'Episode',
          url: '/episode',
          posterUrl: '',
        ).toJson(),
        'timestamp': 1,
      },
    };
  }
}

final class _Gateway implements BackgroundDownloaderGateway {
  _Gateway(this.handle);
  final _Handle handle;
  @override
  Future<void> initialize() async {}
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [handle];
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => handle;
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      handle;
  @override
  Future<void> removeTracking(String taskId) async {}
}

final class _Handle implements DownloadTransportHandle {
  _Handle(this.taskId);
  @override
  final String taskId;
  @override
  DownloadTransportSnapshot get current => DownloadTransportSnapshot(
    taskId: taskId,
    status: DownloadTransportStatus.running,
    progress: .25,
    transferredBytes: 2500000,
    totalBytes: 10000000,
  );
  @override
  Stream<DownloadTransportSnapshot> get snapshots => const Stream.empty();
  @override
  Future<bool> cancel() async => true;
  @override
  Future<bool> pause() async => true;
  @override
  Future<bool> resume() async => true;
}
