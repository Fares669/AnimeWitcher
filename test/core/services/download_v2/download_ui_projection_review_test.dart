import '../../../support/widget_completion.dart';
import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_continued_processing_v2.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/storage_service.dart';

import 'download_v2_test_support.dart';
import '../../../support/memory_storage_service.dart';

import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/download_progress_v2_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:background_downloader/background_downloader.dart' show TaskStatus, DownloadTask;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('tracking cleanup failure stays visible and retry deletes without restarting iOS', () async {
    const channel = MethodChannel('com.animewitcher.app/download_continued_processing');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    final root = await Directory.systemTemp.createTemp('aw-ui-cleanup-retry-');
    final file = File('${root.path}/episode.mp4');
    await file.writeAsBytes([1, 2, 3]);
    final store = _CountingStore();
    final logical = logicalDownloadIdFor(animeId: 'cleanup', episodeKey: '1', variantKey: '480p');
    final gateway = _ReaddGateway();
    final manager = DownloadManagerV2(
      store: store, gateway: gateway, sourceResolver: StaticSourceResolverV2(),
      presentationObservers: [IosDownloadContinuedProcessingObserverV2(forceAvailableForTesting: true)],
    );
    final storage = _DownloadMetadataStorage();
    storage.metadata[logical.value] = {
      'logicalId': logical.value,
      'item': MultimediaItem(title: 'Show', url: 'show://cleanup', posterUrl: '').toJson(),
    };
    final container = ProviderContainer(overrides: [
      downloadManagerV2Provider.overrideWithValue(manager),
      logicalDownloadStoreV2Provider.overrideWithValue(store),
      storageServiceProvider.overrideWithValue(storage),
    ]);
    try {
      final record = await manager.start(DownloadStartRequestV2(
        logicalId: logical, mediaId: 'show', unitKey: 'episode://cleanup',
        variantKey: '480p', destinationPath: file.path, sourceDescriptor: const {},
        allowPause: true, retries: 0, parallelChunks: 1,
      ));
      container.listen(downloadsProvider, (_, __) {});
      await container.read(downloadsProvider.future);
      for (var i = 0; i < 20; i++) { await Future<void>.delayed(Duration.zero); }
      expect(calls.where((call) => call.method == 'start'), isNotEmpty);
      calls.clear();
      gateway.removeTrackingError = StateError('raw owner inventory failed');

      await expectLater(
        container.read(downloadsProvider.notifier).removeDownload(container.read(downloadsProvider).requireValue.single),
        throwsStateError,
      );
      for (var i = 0; i < 20; i++) { await Future<void>.delayed(Duration.zero); }
      final pending = (await store.get(logical))!;
      expect(pending.intent, DownloadUserIntent.canceled);
      expect(pending.failureCategory, DownloadFailureCategory.filesystem);
      expect(manager.snapshotFor(logical)?.status, DownloadTransportStatus.failed);
      final visible = container.read(downloadsProvider).requireValue.single;
      expect(visible.id, record.taskId);
      expect(visible.status, TaskStatus.failed);
      expect(await file.exists(), isTrue);
      expect(storage.metadata, isNotEmpty);
      expect(calls.where((call) => call.method == 'start'), isEmpty);
      expect(calls.where((call) => call.method == 'stop'), isNotEmpty);

      calls.clear();
      gateway.removeTrackingError = null;
      await container.read(downloadsProvider.notifier).retryDownload(visible.id);
      for (var i = 0; i < 20; i++) { await Future<void>.delayed(Duration.zero); }
      expect(await store.get(logical), isNull);
      expect(await file.exists(), isFalse);
      expect(storage.metadata, isEmpty);
      expect(container.read(downloadsProvider).requireValue, isEmpty);
      expect(calls.where((call) => call.method == 'start'), isEmpty);
      expect(gateway.starts, 1, reason: 'Retry must finish deletion instead of starting another generation');
    } finally {
      container.dispose();
      await manager.dispose();
      await root.delete(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });

  for (final lateNativeSettlement in [false, true]) {
  test('cancel timeout keeps the exact live writer visible until ${lateNativeSettlement ? 'native settlement' : 'delete retry succeeds'}', () async {
    final store = _CountingStore();
    const logical = DownloadLogicalId('cancel-timeout-live-writer');
    final gateway = _ReaddGateway();
    final manager = DownloadManagerV2(
      store: store, gateway: gateway, sourceResolver: StaticSourceResolverV2(),
    );
    final storage = _DownloadMetadataStorage();
    storage.metadata[logical.value] = {
      'logicalId': logical.value,
      'item': MultimediaItem(title: 'Show', url: 'show://1', posterUrl: '').toJson(),
    };
    final container = ProviderContainer(overrides: [
      downloadManagerV2Provider.overrideWithValue(manager),
      logicalDownloadStoreV2Provider.overrideWithValue(store),
      storageServiceProvider.overrideWithValue(storage),
    ]);
    try {
      final record = await manager.start(DownloadStartRequestV2(
        logicalId: logical, mediaId: 'show', unitKey: 'episode://cancel-timeout',
        variantKey: '480p', destinationPath: '/tmp/cancel-timeout-live-writer.mp4',
        sourceDescriptor: const {}, allowPause: true, retries: 0, parallelChunks: 1,
      ));
      container.listen(downloadsProvider, (_, __) {});
      await container.read(downloadsProvider.future);
      final handle = gateway.handles[record.taskId]!;
      handle.onCancel = () async => throw TimeoutException('native acknowledgement');

      final original = container.read(downloadsProvider).requireValue.single;
      await expectLater(
        container.read(downloadsProvider.notifier).removeDownload(original),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect((await store.get(logical))?.intent, DownloadUserIntent.canceled);
      final live = container.read(downloadsProvider).requireValue.single;
      expect(live.id, record.taskId);
      expect(live.status, TaskStatus.running);

      if (lateNativeSettlement) {
        handle.setSnapshot(DownloadTransportSnapshot(
          taskId: record.taskId, status: DownloadTransportStatus.canceled, progress: 0,
        ));
      } else {
        handle.onCancel = null;
        await container.read(downloadsProvider.notifier).removeDownload(live);
        expect(await store.get(logical), isNull);
        expect(storage.metadata, isEmpty);
      }
      await Future<void>.delayed(Duration.zero);
      expect(container.read(downloadsProvider).requireValue, isEmpty);
    } finally {
      container.dispose();
      await manager.dispose();
    }
  });
  }

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
      await pumpUntilFuture(tester, manager.initialize(), 'paused writer transport startup');
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
        await pumpUntilFuture(tester, manager.initialize(), 'idle paused transport startup');
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
        ));
        final taskId = matchesCurrentTask ? current.taskId : original.taskId;
        final row = DownloadItem(
          task: DownloadTask(taskId: taskId, url: 'https://example.test/frozen', filename: 'frozen.mp4'),
          status: TaskStatus.paused, progress: .2, item: MultimediaItem(title: 'Show', url: 'show', posterUrl: ''),
          logicalId: logical.value, timestamp: 1, totalBytes: 100,
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
    } finally {
      container?.dispose();
      await manager.dispose();
    }
  });

  for (final sameLogical in [false, true]) {
  test('logical-key metadata wins over a newer recycled task payload sameLogical=$sameLogical', () async {
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
      'logicalId': sameLogical ? logical.value : 'another-variant',
      'timestamp': 100,
      'item': MultimediaItem(title: 'Wrong variant metadata', url: 'show', posterUrl: '').toJson(),
    };
    storage.metadata[logical.value] = {
      'logicalId': logical.value,
      'timestamp': 1,
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
      expect(row.artworkMetadataVerified, isTrue);
    } finally {
      container.dispose();
      await manager.dispose();
    }
  });
  }

  for (final declaredId in [null, 'another-logical-variant']) {
    test('unproven task-key metadata remains visible without artwork ownership declared=$declaredId', () async {
      final store = InMemoryLogicalDownloadStoreV2();
      const logical = DownloadLogicalId('legacy-visible-row');
      final record = LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2, logicalId: logical,
        mediaId: 'show', unitKey: 'episode://legacy', variantKey: '480p',
        generation: 1, taskId: 'legacy-visible-task', intent: DownloadUserIntent.paused,
        destinationPath: '/tmp/ui-legacy-visible.mp4', sourceDescriptor: const {}, updatedAtMillis: 1,
      );
      await store.put(record);
      final manager = DownloadManagerV2(store: store, gateway: _ReaddGateway(), sourceResolver: StaticSourceResolverV2());
      final storage = _DownloadMetadataStorage();
      storage.metadata[record.taskId] = {
        if (declaredId != null) 'logicalId': declaredId,
        'item': MultimediaItem(title: 'Saved legacy row', url: 'show', posterUrl: '').toJson(),
      };
      final container = ProviderContainer(overrides: [
        downloadManagerV2Provider.overrideWithValue(manager), logicalDownloadStoreV2Provider.overrideWithValue(store),
        storageServiceProvider.overrideWithValue(storage),
      ]);
      try {
        container.listen(downloadsProvider, (_, __) {});
        final row = (await container.read(downloadsProvider.future)).single;
        expect(row.item.title, 'Saved legacy row');
        expect(row.logicalId, logical.value);
        expect(row.artworkMetadataVerified, isFalse);
      } finally {
        container.dispose();
        await manager.dispose();
      }
    });
  }

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

  @override
  Future<bool> removeDownloadMetadataIfUnchanged(String taskId, Map<String, dynamic> expected) async {
    if (!const DeepCollectionEquality().equals(metadata[taskId], expected)) return false;
    metadata.remove(taskId);
    return true;
  }
}

final class _ReaddGateway implements BackgroundDownloaderGateway {
  final Map<String, _ReaddHandle> handles = {};
  Object? removeTrackingError;
  int starts = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    starts++;
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
    final error = removeTrackingError;
    if (error != null) throw error;
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
  Future<bool> Function()? onCancel;

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
    final action = onCancel;
    if (action != null) return action();
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
