import 'dart:async';
import 'dart:io';

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

const _archiveSize = 384;
const _liveProvider = 'local-active-fixture';
const _archiveProvider = 'local-archive-fixture';
const _fileContents = [0, 1, 2, 3, 4, 5, 6, 7];

void main() {
  testWidgets(
    'connection safety poll skips archive access but rechecks a live writer',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('aw-connection-poll-'),
      ))!;
      final records = List.generate(
        _archiveSize + 1,
        (index) => _record(index, root.path),
      );
      final active = records.first;
      final store = InMemoryLogicalDownloadStoreV2();
      final transport = _Transport(active.taskId);
      var archiveChecks = 0;
      var writerChecks = 0;
      var liveAvailable = true;
      final manager = DownloadManagerV2(
        store: store,
        gateway: _Gateway(transport),
        sourceResolver: StaticSourceResolverV2(),
        sourceAllowed: (descriptor) {
          if (descriptor['providerId'] == _archiveProvider) {
            archiveChecks++;
            return true;
          }
          if (descriptor['providerId'] == _liveProvider) {
            writerChecks++;
            return liveAvailable;
          }
          throw StateError('Unexpected source lookup');
        },
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
        await manager.dispose();
        await transport.updates.close();
        await root.delete(recursive: true);
      });
      await tester.runAsync(() async {
        for (final record in records) {
          await store.put(record);
          if (record.completedAtMillis != null) {
            await File(record.destinationPath).writeAsBytes(_fileContents);
          }
        }
        await manager.initialize();
        await manager.reconcileAdmission();
      });

      var projections = 0;
      final subscription = container.listen(downloadsProvider, (_, next) {
        if (next.hasValue) projections++;
      });
      try {
        for (var turn = 0; turn < 20 && storage.reads < 2; turn++) {
          await tester.pump();
          if (storage.reads < 2) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
        }
        await tester.pump();
        expect(storage.reads, greaterThanOrEqualTo(2));
        expect(projections, greaterThanOrEqualTo(1));
        final visible = container.read(downloadsProvider).requireValue;
        expect(visible, hasLength(_archiveSize + 1));
        expect(visible.first.id, active.taskId);
        expect(visible.first.status, TaskStatus.running);
        expect(visible.first.activeConnections, 3);
        final archiveIds = visible.skip(1).map((row) => row.id).toList();
        expect(
          visible
              .skip(1)
              .every(
                (row) =>
                    row.status == TaskStatus.complete &&
                    row.activeConnections == 0 &&
                    row.progress == 1,
              ),
          isTrue,
        );

        final archiveBefore = archiveChecks;
        final writerBefore = writerChecks;
        final before = projections;
        final beforeReads = storage.reads;
        for (var tick = 0; tick < 5; tick++) {
          await tester.pump(const Duration(seconds: 2));
        }
        expect(archiveChecks - archiveBefore, 0);
        expect(writerChecks - writerBefore, 5);
        expect(projections, before);
        expect(storage.reads, beforeReads);
        expect(container.read(downloadsProvider).requireValue, same(visible));

        // A provider availability change emits no snapshot at all. The actual
        // two-second fallback must still clear the previously visible writer.
        liveAvailable = false;
        await tester.pump(const Duration(seconds: 2));
        final hidden = container.read(downloadsProvider).requireValue;
        expect(hidden.map((row) => row.id), archiveIds);
        expect(visible.first.activeConnections, 3);
        expect(storage.reads, beforeReads);

        // Restoration remains a real manager presentation event, not a
        // fabricated UI state. Keep exact task identity and archive order.
        liveAvailable = true;
        transport.report(5);
        await tester.pump();
        final revived = container.read(downloadsProvider).requireValue;
        expect(revived.first.id, active.taskId);
        expect(revived.first.activeConnections, 5);
        expect(revived.skip(1).map((row) => row.id), archiveIds);
        expect(storage.reads, beforeReads);

        transport.report(0, status: DownloadTransportStatus.paused);
        await tester.pump();
        final stopped = container.read(downloadsProvider).requireValue;
        final stoppedRow = stopped.singleWhere(
          (row) => row.id == active.taskId,
        );
        expect(stoppedRow.status, TaskStatus.paused);
        expect(stoppedRow.activeConnections, 0);
        final idleArchiveBefore = archiveChecks;
        final idleWriterBefore = writerChecks;
        final idleProjectionsBefore = projections;
        await tester.pump(const Duration(seconds: 2));
        expect(archiveChecks - idleArchiveBefore, 0);
        expect(writerChecks - idleWriterBefore, 0);
        expect(projections, idleProjectionsBefore);
        expect(storage.reads, beforeReads);
      } finally {
        subscription.close();
        container.dispose();
      }
    },
  );
}

LogicalDownloadRecordV2 _record(int index, String directory) {
  final id = logicalDownloadIdFor(
    animeId: 'connection-safety-poll',
    episodeKey: '$index',
    variantKey: 'fixture',
  );
  return LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: id,
    mediaId: 'connection-safety-poll',
    unitKey: '$index',
    variantKey: 'fixture',
    generation: 1,
    taskId: taskIdForGeneration(id, 1),
    intent: DownloadUserIntent.active,
    destinationPath: '$directory/episode-$index.mp4',
    sourceDescriptor: {
      'providerId': index == 0 ? _liveProvider : _archiveProvider,
    },
    expectedBytes: _fileContents.length,
    completedAtMillis: index == 0 ? null : index,
    updatedAtMillis: index + 1,
  );
}

final class _Storage extends MemoryStorageService {
  _Storage(List<LogicalDownloadRecordV2> records)
    : metadata = {
        for (final record in records)
          record.logicalId.value: {
            'timestamp': record.updatedAtMillis,
            'item': MultimediaItem(
              title: 'Offline fixture',
              url: '/fixture/connection-safety-poll',
              posterUrl: '',
            ).toJson(),
          },
      };

  final Map<String, Map<String, dynamic>> metadata;
  int reads = 0;

  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async {
    reads++;
    return metadata;
  }
}

final class _Gateway implements BackgroundDownloaderGateway {
  _Gateway(this.transport);
  final _Transport transport;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [transport];

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async =>
      taskId == transport.taskId ? transport : null;

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError('No new transfer is allowed in the local fixture');

  @override
  Future<void> removeTracking(String taskId) async {}
}

final class _Transport implements DownloadTransportHandle {
  _Transport(this.taskId);

  @override
  final String taskId;
  final updates = StreamController<DownloadTransportSnapshot>.broadcast(
    sync: true,
  );

  var _count = 3;
  var _status = DownloadTransportStatus.running;

  @override
  DownloadTransportSnapshot get current => DownloadTransportSnapshot(
    taskId: taskId,
    status: _status,
    progress: 0.5,
    transferredBytes: 4,
    totalBytes: _fileContents.length,
    activeConnections: _count,
  );

  void report(
    int count, {
    DownloadTransportStatus status = DownloadTransportStatus.running,
  }) {
    _count = count;
    _status = status;
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
