import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../core/services/download_v2/download_v2_test_support.dart';
import '../../../support/memory_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a live download only replaces the changed presentation row', () async {
    const rowCount = 200;
    const progressSamples = 12;
    final records = List.generate(rowCount, _record);
    final activeRecord = records.first;
    final store = InMemoryLogicalDownloadStoreV2();
    for (final record in records) {
      await store.put(record);
    }
    final transport = _Transport(activeRecord.taskId);
    final manager = DownloadManagerV2(
      store: store,
      gateway: _Gateway(transport),
      sourceResolver: StaticSourceResolverV2(),
    );
    final storage = _Storage(records);
    final container = ProviderContainer(
      overrides: [
        downloadManagerV2Provider.overrideWithValue(manager),
        logicalDownloadStoreV2Provider.overrideWithValue(store),
        storageServiceProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await manager.dispose();
      await transport.updates.close();
    });
    await manager.initialize();

    // Wait for the first durable records-stream projection, not merely the
    // provider's initial build, to exclude startup metadata invalidation.
    final ready = Completer<void>();
    final subscription = container.listen(downloadsProvider, (_, next) {
      if (!ready.isCompleted && storage.metadataReads >= 2 && next.hasValue) {
        ready.complete();
      }
    });
    addTearDown(subscription.close);
    await ready.future;
    final metadataReads = storage.metadataReads;

    var previous = container.read(downloadsProvider).requireValue;
    expect(previous, hasLength(rowCount));
    final activeIndex = previous.indexWhere(
      (row) => row.id == transport.taskId,
    );
    expect(activeIndex, isNonNegative);
    var replacedRows = 0;
    var replacedTasks = 0;
    for (var sample = 1; sample <= progressSamples; sample++) {
      final currentUpdated = Completer<List<DownloadItem>>();
      final next = container.listen(downloadsProvider, (_, value) {
        final rows = value.value;
        if (rows != null &&
            rows[activeIndex].transferredBytes == sample &&
            !currentUpdated.isCompleted) {
          currentUpdated.complete(rows);
        }
      });
      transport.report(sample);
      final current = await currentUpdated.future;
      next.close();
      expect(current[activeIndex].progress, sample / 100);
      expect(current[activeIndex].activeConnections, sample % 2 + 1);
      expect(current[activeIndex].status, TaskStatus.running);
      for (var i = 0; i < current.length; i++) {
        if (!identical(current[i], previous[i])) replacedRows++;
        if (!identical(current[i].task, previous[i].task)) replacedTasks++;
      }
      previous = current;
    }
    expect((replacedRows, replacedTasks), (progressSamples, 0));
    expect(storage.metadataReads, metadataReads);
  });
}

LogicalDownloadRecordV2 _record(int i) {
  final id = logicalDownloadIdFor(
    animeId: 'local-fixture',
    episodeKey: '$i',
    variantKey: 'test',
  );
  return LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: id,
    mediaId: 'local-fixture',
    unitKey: '$i',
    variantKey: 'test',
    generation: 1,
    taskId: taskIdForGeneration(id, 1),
    intent: i == 0 ? DownloadUserIntent.active : DownloadUserIntent.failed,
    destinationPath: 'downloads/row-reuse-test-$i.mp4',
    sourceDescriptor: const {'providerId': 'test'},
    expectedBytes: 100,
    updatedAtMillis: i,
  );
}

final class _Storage extends MemoryStorageService {
  _Storage(this.records);
  final List<LogicalDownloadRecordV2> records;
  int metadataReads = 0;

  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async {
    metadataReads++;
    return {
      for (final record in records)
        record.logicalId.value: {
          'logicalId': record.logicalId.value,
          'timestamp': record.updatedAtMillis,
          'trackingUrl': '/episode/${record.unitKey}',
          'item': MultimediaItem(
            title: 'Local fixture',
            url: '/local-fixture',
            posterUrl: '',
          ).toJson(),
        },
    };
  }
}

final class _Gateway implements BackgroundDownloaderGateway {
  _Gateway(this.transport);
  final _Transport transport;

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async =>
      taskId == transport.taskId ? transport : null;

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [transport];

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError('Fixture only attaches the existing active transport');

  @override
  Future<void> removeTracking(String taskId) async {}
}

final class _Transport implements DownloadTransportHandle {
  _Transport(this.taskId);
  @override
  final String taskId;

  final updates = StreamController<DownloadTransportSnapshot>.broadcast();
  int _sent = 0;

  @override
  DownloadTransportSnapshot get current => DownloadTransportSnapshot(
    taskId: taskId,
    status: DownloadTransportStatus.running,
    progress: _sent / 100,
    transferredBytes: _sent,
    totalBytes: 100,
    activeConnections: _sent % 2 + 1,
  );

  void report(int bytes) {
    _sent = bytes;
    updates.add(current);
  }

  @override
  Stream<DownloadTransportSnapshot> get snapshots => updates.stream;

  @override
  Future<bool> cancel() async => true;

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;
}
