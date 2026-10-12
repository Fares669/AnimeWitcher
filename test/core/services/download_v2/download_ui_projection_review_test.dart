import '../../../support/widget_completion.dart';
import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';

import 'download_v2_test_support.dart';
import '../../../support/memory_storage_service.dart';

import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:background_downloader/background_downloader.dart' show TaskStatus, DownloadTask;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('paused intent exposes a live writer and refreshes progress without durable reads', (tester) async {
    final store = _CountingStore();
    const logical = DownloadLogicalId('paused-live-writer');
    final record = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: logical, mediaId: 'show', unitKey: 'episode://1',
      variantKey: '480p', generation: 1, taskId: 'paused-live-task',
      intent: DownloadUserIntent.paused, destinationPath: '/tmp/live-writer.mp4',
      sourceDescriptor: const {}, updatedAtMillis: 1,
    );
    await store.put(record);
    final gateway = _ReaddGateway();
    final handle = _ReaddHandle(record.taskId)..rejectPause = true;
    gateway.handles[record.taskId] = handle;
    final manager = DownloadManagerV2(
      store: store, gateway: gateway, sourceResolver: StaticSourceResolverV2(),
    );
    final storage = _DownloadMetadataStorage();
    storage.metadata[logical.value] = {
      'logicalId': logical.value, 'timestamp': 1,
      'item': MultimediaItem(title: 'Show', url: 'show://1', posterUrl: '').toJson(),
    };
    final container = ProviderContainer(overrides: [
      downloadManagerV2Provider.overrideWithValue(manager),
      logicalDownloadStoreV2Provider.overrideWithValue(store),
      storageServiceProvider.overrideWithValue(storage),
    ]);
    try {
      container.listen(downloadsProvider, (_, __) {});
      await pumpUntilFuture(tester, container.read(downloadsProvider.future), 'paused writer downloads projection');
      await tester.pump();
      expect(manager.snapshotFor(logical)?.status, DownloadTransportStatus.running);
      expect(container.read(downloadsProvider).requireValue.single.status, TaskStatus.running);
      final reads = storage.metadataReads;
      final storeReads = store.allReads;
      handle.setProgress(.7);
      await tester.pump(const Duration(seconds: 1));
      expect(container.read(downloadsProvider).requireValue.single.progress, .7);
      expect(storage.metadataReads, reads);
      expect(store.allReads, storeReads);
    } finally {
      container.dispose();
      await pumpUntilFuture(tester, manager.dispose(), 'paused writer manager disposal');
    }
  });

  for (final withHandle in [false, true]) {
    testWidgets('paused intent with ${withHandle ? 'paused' : 'missing'} transport remains paused and idle', (tester) async {
      final store = _CountingStore();
      const logical = DownloadLogicalId('genuinely-paused');
      final record = LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2, logicalId: logical,
        mediaId: 'show', unitKey: 'episode://paused', variantKey: '480p',
        generation: 1, taskId: 'genuinely-paused-task', intent: DownloadUserIntent.paused,
        destinationPath: '/tmp/ui-genuinely-paused.mp4', sourceDescriptor: const {}, updatedAtMillis: 1,
      );
      await store.put(record);
      final gateway = _ReaddGateway();
      if (withHandle) {
        final handle = _ReaddHandle(record.taskId);
        await handle.pause();
        gateway.handles[record.taskId] = handle;
      }
      final manager = DownloadManagerV2(store: store, gateway: gateway, sourceResolver: StaticSourceResolverV2());
      final storage = _DownloadMetadataStorage();
      storage.metadata[logical.value] = {
        'logicalId': logical.value,
        'item': MultimediaItem(title: 'Show', url: 'show://1', posterUrl: '').toJson(),
      };
      final container = ProviderContainer(overrides: [
        downloadManagerV2Provider.overrideWithValue(manager), logicalDownloadStoreV2Provider.overrideWithValue(store),
        storageServiceProvider.overrideWithValue(storage),
      ]);
      try {
        var publications = 0;
        container.listen(downloadsProvider, (_, next) { if (next.hasValue) publications++; });
        await pumpUntilFuture(tester, container.read(downloadsProvider.future), 'acceptance downloads projection');
        await tester.pump();
        expect(container.read(downloadsProvider).requireValue.single.status, TaskStatus.paused);
        final before = publications;
        final metadataReads = storage.metadataReads;
        final storeReads = store.allReads;
        await tester.pump(const Duration(seconds: 2));
        expect(publications, before);
        expect(storage.metadataReads, metadataReads);
        expect(store.allReads, storeReads);
      } finally {
        container.dispose();
        await pumpUntilFuture(tester, manager.dispose(), 'acceptance manager disposal');
      }
    });
  }

  for (final otherStatus in [TaskStatus.running, TaskStatus.complete]) {
    test('two logical variants beside $otherStatus have no ambiguous URL alias', () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final manager = DownloadManagerV2(store: store, gateway: _ReaddGateway(), sourceResolver: StaticSourceResolverV2());
      final rows = [
        _projectionRow('selected', TaskStatus.running), _projectionRow('other', otherStatus),
      ];
      final container = ProviderContainer(overrides: [
        downloadsProvider.overrideWith(() => _ProjectedRows(rows)),
        downloadManagerV2Provider.overrideWithValue(manager),
      ]);
      try {
        await container.read(downloadsProvider.future);
        final progress = container.read(downloadProgressProvider);
        expect(progress.keys, containsAll(['selected', 'other']));
        expect(progress, isNot(contains('episode://same')));
        expect(progress['selected']?.taskId, 'selected-task');
        expect(progress['other']?.taskId, 'other-task');
      } finally {
        container.dispose();
        await manager.dispose();
      }
    });
  }

  test('one logical variant preserves the legacy tracking URL alias', () async {
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(), gateway: _ReaddGateway(), sourceResolver: StaticSourceResolverV2(),
    );
    final container = ProviderContainer(overrides: [
      downloadsProvider.overrideWith(() => _ProjectedRows([_projectionRow('selected', TaskStatus.running)])),
      downloadManagerV2Provider.overrideWithValue(manager),
    ]);
    try {
      await container.read(downloadsProvider.future);
      final progress = container.read(downloadProgressProvider);
      expect(identical(progress['selected'], progress['episode://same']), isTrue);
    } finally {
      container.dispose();
      await manager.dispose();
    }
  });

  for (final matchesCurrentTask in [false, true]) {
    test('progress telemetry accepts only the frozen row task matches=$matchesCurrentTask', () async {
      final store = InMemoryLogicalDownloadStoreV2();
      const logical = DownloadLogicalId('frozen-generation');
      final gateway = _ReaddGateway();
      final manager = DownloadManagerV2(store: store, gateway: gateway, sourceResolver: StaticSourceResolverV2());
      ProviderContainer? container;
      try {
        await manager.start(DownloadStartRequestV2(
          logicalId: logical, mediaId: 'show', unitKey: 'episode://frozen', variantKey: '480p',
          destinationPath: '/tmp/frozen-generation.mp4', sourceDescriptor: const {},
          allowPause: true, retries: 0, parallelChunks: 1,
        ));
        final original = (await store.get(logical))!;
        await manager.restart(logical);
        final current = (await store.get(logical))!;
        gateway.handles[current.taskId]!.setSnapshot(DownloadTransportSnapshot(
          taskId: current.taskId, status: DownloadTransportStatus.running, progress: .7,
          transferredBytes: 700, totalBytes: 1000, networkSpeedMBps: 2,
          timeRemaining: const Duration(seconds: 3),
        ));
        final taskId = matchesCurrentTask ? current.taskId : original.taskId;
        final row = DownloadItem(
          task: DownloadTask(taskId: taskId, url: 'https://example.test/frozen', filename: 'frozen.mp4'),
          status: TaskStatus.paused, progress: .2, item: MultimediaItem(title: 'Show', url: 'show', posterUrl: ''),
          logicalId: logical.value, timestamp: 1, totalBytes: 100,
          networkSpeedMBps: .5, timeRemaining: const Duration(seconds: 8),
        );
        container = ProviderContainer(overrides: [
          downloadsProvider.overrideWith(() => _ProjectedRows([row])),
          downloadManagerV2Provider.overrideWithValue(manager),
        ]);
        await container.read(downloadsProvider.future);
        final data = container.read(downloadProgressProvider)[logical.value]!;
        expect(data.taskId, taskId);
        expect(data.progress, matchesCurrentTask ? .7 : .2);
        expect(data.totalSize, matchesCurrentTask ? 1000 : 100);
        expect(data.networkSpeed, matchesCurrentTask ? 2 : .5);
        expect(data.timeRemaining, Duration(seconds: matchesCurrentTask ? 3 : 8));
      } finally {
        container?.dispose();
        await manager.dispose();
      }
    });
  }

  test('list telemetry ignores a newer task snapshot while durable row remains older', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    const logical = DownloadLogicalId('frozen-list-generation');
    final gateway = _ReaddGateway();
    final manager = DownloadManagerV2(store: store, gateway: gateway, sourceResolver: StaticSourceResolverV2());
    ProviderContainer? container;
    try {
      await manager.start(DownloadStartRequestV2(
        logicalId: logical, mediaId: 'show', unitKey: 'episode://frozen-list', variantKey: '480p',
        destinationPath: '/tmp/frozen-list-generation.mp4', sourceDescriptor: const {},
        allowPause: true, retries: 0, parallelChunks: 1, expectedBytes: 100,
      ));
      final original = (await store.get(logical))!;
      await manager.restart(logical);
      final current = (await store.get(logical))!;
      gateway.handles[current.taskId]!.setSnapshot(DownloadTransportSnapshot(
        taskId: current.taskId, status: DownloadTransportStatus.running, progress: .7,
        transferredBytes: 700, totalBytes: 1000, networkSpeedMBps: 2,
        timeRemaining: const Duration(seconds: 3),
      ));
      await store.put(original.copyWith(intent: DownloadUserIntent.paused));
      final storage = _DownloadMetadataStorage();
      storage.metadata[logical.value] = {'logicalId': logical.value, 'item': MultimediaItem(title: 'Show', url: 'show', posterUrl: '').toJson()};
      container = ProviderContainer(overrides: [
        downloadManagerV2Provider.overrideWithValue(manager), logicalDownloadStoreV2Provider.overrideWithValue(store),
        storageServiceProvider.overrideWithValue(storage),
      ]);
      container.listen(downloadsProvider, (_, __) {});
      final row = (await container.read(downloadsProvider.future)).single;
      expect(row.id, original.taskId);
      expect(row.status, TaskStatus.paused);
      expect(row.progress, 0);
      expect(row.totalBytes, 100);
      expect(row.transferredBytes, isNull);
      expect(row.networkSpeedMBps, -1);
      expect(row.timeRemaining, Duration.zero);
    } finally {
      container?.dispose();
      await manager.dispose();
    }
  });

  test('logical metadata wins over a recycled task key identifying another variant', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    const logical = DownloadLogicalId('exact-metadata-variant');
    final record = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2, logicalId: logical,
      mediaId: 'show', unitKey: 'episode://metadata', variantKey: '480p',
      generation: 1, taskId: 'reused-metadata-task', intent: DownloadUserIntent.paused,
      destinationPath: '/tmp/ui-exact-metadata.mp4', sourceDescriptor: const {}, updatedAtMillis: 1,
    );
    await store.put(record);
    final manager = DownloadManagerV2(store: store, gateway: _ReaddGateway(), sourceResolver: StaticSourceResolverV2());
    final storage = _DownloadMetadataStorage();
    storage.metadata[record.taskId] = {
      'logicalId': 'another-variant',
      'item': MultimediaItem(title: 'Wrong variant metadata', url: 'show', posterUrl: '').toJson(),
    };
    storage.metadata[logical.value] = {
      'logicalId': logical.value,
      'item': MultimediaItem(title: 'Exact variant metadata', url: 'show', posterUrl: '').toJson(),
    };
    final container = ProviderContainer(overrides: [
      downloadManagerV2Provider.overrideWithValue(manager), logicalDownloadStoreV2Provider.overrideWithValue(store),
      storageServiceProvider.overrideWithValue(storage),
    ]);
    try {
      container.listen(downloadsProvider, (_, __) {});
      final row = (await container.read(downloadsProvider.future)).single;
      expect(row.logicalId, logical.value);
      expect(row.item.title, 'Exact variant metadata');
    } finally {
      container.dispose();
      await manager.dispose();
    }
  });

}

final class _DownloadMetadataStorage extends MemoryStorageService {
  final Map<String, Map<String, dynamic>> metadata = {};
  int metadataReads = 0;

  @override
  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async {
    metadataReads++;
    return Map<String, Map<String, dynamic>>.from(metadata);
  }

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
  _ReaddHandle(this.taskId) : _current = DownloadTransportSnapshot(
    taskId: taskId,
    status: DownloadTransportStatus.running,
    progress: 0,
  );

  @override
  final String taskId;

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _changes =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _changes.stream;

  bool rejectPause = false;

  void setSnapshot(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    _changes.add(snapshot);
  }

  void setProgress(double progress) {
    _current = DownloadTransportSnapshot(
      taskId: taskId, status: DownloadTransportStatus.running, progress: progress,
    );
    _changes.add(_current);
  }

  @override
  Future<bool> pause() async {
    if (rejectPause) throw StateError('writer still running');
    _current = DownloadTransportSnapshot(
      taskId: taskId, status: DownloadTransportStatus.paused, progress: _current.progress,
    );
    return true;
  }

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.canceled,
      progress: 0,
    );
    _changes.add(_current);
    return true;
  }
}

class _CountingStore implements LogicalDownloadStoreV2 {
  final _store = InMemoryLogicalDownloadStoreV2();
  int allReads = 0;
  @override
  Future<List<LogicalDownloadRecordV2>> all() { allReads++; return _store.all(); }
  @override
  Future<LogicalDownloadRecordV2?> get(DownloadLogicalId id) => _store.get(id);
  @override
  Future<void> put(LogicalDownloadRecordV2 record) => _store.put(record);
  @override
  Future<void> remove(DownloadLogicalId id) => _store.remove(id);
  @override
  Future<LogicalDownloadRecordV2?> mutate(DownloadLogicalId id, LogicalDownloadRecordV2? Function(LogicalDownloadRecordV2?) change) => _store.mutate(id, change);
}

class _ProjectedRows extends DownloadsNotifier {
  _ProjectedRows(this.rows);
  final List<DownloadItem> rows;
  @override
  Future<List<DownloadItem>> build() async => rows;
}

DownloadItem _projectionRow(String id, TaskStatus status) => DownloadItem(
  task: DownloadTask(taskId: '$id-task', url: 'https://example.test/$id', filename: '$id.mp4'),
  status: status, progress: .4,
  item: MultimediaItem(title: 'Show', url: 'show://1', posterUrl: ''),
  logicalId: id, trackingUrl: 'episode://same', timestamp: 1,
);
