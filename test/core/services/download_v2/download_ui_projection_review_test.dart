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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:background_downloader/background_downloader.dart' show TaskStatus;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('paused intent exposes a live writer and refreshes progress without durable reads', (tester) async {
    final store = InMemoryLogicalDownloadStoreV2();
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
      await container.read(downloadsProvider.future);
      await tester.pump();
      expect(manager.snapshotFor(logical)?.status, DownloadTransportStatus.running);
      expect(container.read(downloadsProvider).requireValue.single.status, TaskStatus.running);
      final reads = storage.metadataReads;
      handle.setProgress(.7);
      await tester.pump(const Duration(seconds: 1));
      expect(container.read(downloadsProvider).requireValue.single.progress, .7);
      expect(storage.metadataReads, reads);
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
