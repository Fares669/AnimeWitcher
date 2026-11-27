import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../core/services/download_v2/download_v2_test_support.dart';
import '../../../support/memory_storage_service.dart';

const _batchSize = 8;
const _rowCount = 200;
const _bytes = 100;
const _editedTitle = 'Recently stored title';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a verified completion burst refreshes metadata once more after a held read', () async {
    final folder = await Directory.systemTemp.createTemp('aw-metadata-burst-');
    addTearDown(() => folder.delete(recursive: true));
    final sourceRecords = List.generate(
      _rowCount,
      (i) => _record(i, folder.path),
    );
    final active = sourceRecords.take(_batchSize).toList();
    final transports = [for (final row in active) _Transport(row.taskId)];
    final store = InMemoryLogicalDownloadStoreV2();
    for (final row in sourceRecords) {
      await store.put(row);
    }
    final gateway = _Gateway(transports);
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: StaticSourceResolverV2(),
    );
    final worker = DownloadPersistenceWorker.forDirectory(
      '${folder.path}/metadata',
    );
    addTearDown(worker.close);
    final storage = _Storage(worker);
    for (final row in sourceRecords) {
      await storage.write(row);
    }
    final container = ProviderContainer(
      overrides: [
        downloadManagerV2Provider.overrideWithValue(manager),
        logicalDownloadStoreV2Provider.overrideWithValue(store),
        storageServiceProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(() async {
      storage.release();
      container.dispose();
      await manager.dispose();
      for (final handle in transports) {
        await handle.updates.close();
      }
    });

    await manager.initialize();
    var updates = 0;
    final presentationSubscription = container.listen(downloadsProvider, (
      _,
      next,
    ) {
      if (next.hasValue) updates++;
    });
    addTearDown(presentationSubscription.close);
    await _until(() => storage.reads >= 2 && updates >= 2);
    final startingRows = container.read(downloadsProvider).requireValue;
    expect(startingRows, hasLength(_rowCount));
    expect(
      startingRows.where((row) => row.status == TaskStatus.enqueued),
      hasLength(_batchSize),
    );

    final durable = <String>{};
    final recordsSubscription = manager.records.listen((rows) {
      durable.addAll([
        for (final row in rows)
          if (row.completedAtMillis != null) row.taskId,
      ]);
    });
    addTearDown(recordsSubscription.cancel);

    final initialReads = storage.reads;
    final initialMaterializedRows = storage.materializedRows;
    storage.hold = Completer<void>();
    for (var i = 0; i < active.length; i++) {
      final row = active[i];
      await File(row.destinationPath).writeAsBytes(List.filled(_bytes, i));
      transports[i].complete();
      await _until(() => durable.contains(row.taskId));
      if (i == 0) {
        await _until(() => storage.captured > 0);
        await storage.write(active.last, title: _editedTitle);
      }
    }
    await _until(() => gateway.forgotten.length == _batchSize);
    // Let both subscriptions consume the last published record list.
    await Future<void>.delayed(Duration.zero);
    final readsBeforeRelease = storage.reads - initialReads;
    storage.release();
    await _until(() {
      final rows = container.read(downloadsProvider).value;
      return rows?.where((row) => row.status == TaskStatus.complete).length ==
              _batchSize &&
          rows!.any((row) => row.item.title == _editedTitle) &&
          storage.pending == 0;
    });

    final settled = container.read(downloadsProvider).requireValue;
    final completed = settled
        .where((row) => row.status == TaskStatus.complete)
        .toList();
    expect(settled, hasLength(_rowCount));
    expect(
      completed.map((row) => row.id),
      active.reversed.map((row) => row.taskId),
    );
    expect(completed.first.item.title, _editedTitle);
    for (final row in completed) {
      expect(row.progress, 1);
      expect(row.transferredBytes, _bytes);
      expect(row.totalBytes, _bytes);
      expect(await File(row.destinationPath).length(), _bytes);
    }
    expect(durable, active.map((row) => row.taskId).toSet());
    expect(gateway.forgotten, active.map((row) => row.taskId).toSet());
    expect(
      startingRows.where((row) => row.status == TaskStatus.enqueued),
      hasLength(_batchSize),
    );

    final reads = storage.reads - initialReads;
    final materializedRows = storage.materializedRows - initialMaterializedRows;
    // Preserve one immediate read plus one fresh read after the overlap.
    expect(readsBeforeRelease, 1);
    expect(reads, 2);
    expect(materializedRows, _rowCount * reads);
  });
}

Future<void> _until(bool Function() condition) async {
  final timer = Stopwatch()..start();
  while (!condition()) {
    if (timer.elapsed > const Duration(seconds: 8)) {
      fail('Timed out waiting for local completion fixture');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

LogicalDownloadRecordV2 _record(int i, String directory) {
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
    intent: i < _batchSize
        ? DownloadUserIntent.active
        : DownloadUserIntent.failed,
    destinationPath: '$directory/episode-$i.mp4',
    sourceDescriptor: {'providerId': 'test'},
    expectedBytes: _bytes,
    updatedAtMillis: i,
  );
}

final class _Storage extends MemoryStorageService {
  _Storage(this.worker)
    : persistence = StorageService(downloadPersistenceWorker: worker);

  final DownloadPersistenceWorker worker;
  final StorageService persistence;
  int reads = 0;
  int materializedRows = 0;
  int pending = 0;
  int captured = 0;
  Completer<void>? hold;

  Future<void> write(LogicalDownloadRecordV2 record, {String? title}) async {
    await worker.run('hive.put', [
      StorageService.kDownloadMetadataBox,
      record.logicalId.value,
      {
        // No artwork authority in this completion/readback fixture.
        'timestamp': record.updatedAtMillis,
        'trackingUrl': '/episode/${record.unitKey}',
        'item': MultimediaItem(
          title: title ?? 'Episode ${record.unitKey}',
          url: '/local-fixture',
          posterUrl: '',
        ).toJson(),
      },
    ]);
  }

  void release() {
    final current = hold;
    hold = null;
    current?.complete();
  }

  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async {
    reads++;
    final current = hold;
    if (current != null) pending++;
    try {
      // Hold delivery of an already read, real persisted snapshot, not the
      // worker: later durable writes and completions are free to settle.
      final snapshot = await persistence.getAllDownloadMetadata();
      materializedRows += snapshot.length;
      if (current != null) {
        captured++;
        await current.future;
      }
      return snapshot;
    } finally {
      if (current != null) pending--;
    }
  }
}

final class _Gateway implements BackgroundDownloaderGateway {
  _Gateway(this.transports);
  final List<_Transport> transports;
  final forgotten = <String>{};

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async =>
      transports.where((handle) => handle.taskId == taskId).firstOrNull;

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => transports;

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError('No transport should start from the fixture');

  @override
  Future<void> removeTracking(String taskId) async {
    forgotten.add(taskId);
  }
}

final class _Transport implements DownloadTransportHandle {
  _Transport(this.taskId);
  @override
  final String taskId;

  final updates = StreamController<DownloadTransportSnapshot>.broadcast();
  bool _complete = false;

  @override
  DownloadTransportSnapshot get current => DownloadTransportSnapshot(
    taskId: taskId,
    status: _complete
        ? DownloadTransportStatus.complete
        : DownloadTransportStatus.queued,
    progress: _complete ? 1 : 0,
    transferredBytes: _complete ? _bytes : 0,
    totalBytes: _bytes,
  );

  void complete() {
    _complete = true;
    updates.add(current);
  }

  @override
  Stream<DownloadTransportSnapshot> get snapshots => updates.stream;

  @override
  Future<bool> cancel() async => throw StateError('Unexpected cancel');

  @override
  Future<bool> pause() async => throw StateError('Unexpected pause');

  @override
  Future<bool> resume() async => throw StateError('Unexpected resume');
}
