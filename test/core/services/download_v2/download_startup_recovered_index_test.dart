import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';
// The path_provider platform facade is how this fixture keeps file operations
// confined to a temporary fixture on every platform.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'download_v2_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'opening Downloads visits each recovered task once, not once per row',
    () async {
      final root = await _usePrivatePaths();
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _RecoveryGateway();
      const recordCount = 48;
      const recoveredCount = 96;
      for (var i = 0; i < recordCount; ++i) {
        final id = _videoId(i);
        await store.put(_row(root, id, i));
      }
      for (var i = 0; i < recoveredCount; ++i) {
        gateway.add(
          taskIdForGeneration(_videoId(recordCount + i), 1),
          DownloadTransportStatus.complete,
        );
      }
      final resolver = StaticSourceResolverV2();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
      );
      addTearDown(manager.dispose);

      final rows = await manager.records.first;
      await manager.initialize();
      expect(rows, hasLength(recordCount));
      expect(
        rows.every((row) => row.intent == DownloadUserIntent.canceled),
        isTrue,
      );
      expect(gateway.recoveredIdReads, recoveredCount);
      expect(gateway.lookupIds, isEmpty);
      expect(gateway.removedIds, isEmpty);
      expect(resolver.calls, 0);
    },
  );

  test(
    'obsolete chapter generations keep ascending, exact parent ownership',
    () async {
      final root = await _usePrivatePaths();
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _RecoveryGateway();
      final id = logicalDownloadIdForMangaChapter(
        mangaId: 'fixture-title',
        chapterId: 'fixture-chapter',
      );
      final unrelatedId = logicalDownloadIdForMangaChapter(
        mangaId: 'unrelated-title',
        chapterId: 'unrelated-chapter',
      );
      const current = 4;
      String parent(int generation) => taskIdForGeneration(id, generation);
      final delayed = gateway.add(
        parent(2),
        DownloadTransportStatus.running,
        rehydrated: false,
      );
      final observed = gateway.add(parent(3), DownloadTransportStatus.running);
      final firstChild = gateway.add(
        '${parent(2)}_p0001',
        DownloadTransportStatus.running,
      );
      final secondChild = gateway.add(
        '${parent(2)}_p0002',
        DownloadTransportStatus.running,
      );
      final sameGeneration = gateway.add(
        '${parent(current)}_p0001',
        DownloadTransportStatus.complete,
      );
      final future = gateway.add(
        parent(current + 1),
        DownloadTransportStatus.complete,
      );
      final invalid = gateway.add(
        '${parent(1)}_p0000',
        DownloadTransportStatus.complete,
      );
      final unrelated = gateway.add(
        taskIdForGeneration(unrelatedId, 1),
        DownloadTransportStatus.complete,
      );
      await store.put(_row(root, id, 0, generation: current, chapter: true));

      final resolver = StaticSourceResolverV2();
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      expect(gateway.lookupIds, [parent(2), parent(current)]);
      expect(gateway.removedIds, [parent(2), parent(3)]);
      expect(delayed.cancelCalls, 1);
      expect(observed.cancelCalls, 1);
      for (final handle in [
        firstChild,
        secondChild,
        sameGeneration,
        future,
        invalid,
        unrelated,
      ]) {
        expect(handle.cancelCalls, 0);
      }
      final saved = await store.get(id);
      expect(saved?.taskId, parent(current));
      expect(saved?.generation, current);
      expect(saved?.intent, DownloadUserIntent.canceled);
      expect(manager.snapshotFor(id)?.status, DownloadTransportStatus.canceled);
      expect(resolver.calls, 0);
    },
  );
}

DownloadLogicalId _videoId(int episode) => logicalDownloadIdFor(
  animeId: 'fixture-series',
  episodeKey: '$episode',
  variantKey: 'normal',
);

LogicalDownloadRecordV2 _row(
  Directory root,
  DownloadLogicalId id,
  int index, {
  int generation = 1,
  bool chapter = false,
}) => LogicalDownloadRecordV2(
  schemaVersion: kLogicalDownloadSchemaVersionV2,
  logicalId: id,
  mediaKind: chapter
      ? DownloadMediaKind.mangaChapter
      : DownloadMediaKind.videoEpisode,
  mediaId: 'fixture-series',
  unitKey: '$index',
  variantKey: 'normal',
  generation: generation,
  taskId: taskIdForGeneration(id, generation),
  intent: DownloadUserIntent.canceled,
  destinationPath:
      '${root.path}${Platform.pathSeparator}artifacts${Platform.pathSeparator}${id.value}.mp4',
  sourceDescriptor: const {'providerId': 'fixture-native'},
  updatedAtMillis: index + 1,
);

Future<Directory> _usePrivatePaths() async {
  final root = await Directory.systemTemp.createTemp('aw-download-index-');
  final previous = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _FixturePaths(root.path);
  addTearDown(() async {
    PathProviderPlatform.instance = previous;
    await root.delete(recursive: true);
  });
  return root;
}

final class _FixturePaths extends PathProviderPlatform {
  _FixturePaths(this.path);

  final String path;
  @override
  Future<String?> getDownloadsPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

final class _RecoveryGateway implements BackgroundDownloaderGateway {
  final handles = <String, _Handle>{};
  final recovered = <_Handle>[];
  final lookupIds = <String>[];
  final removedIds = <String>[];
  int recoveredIdReads = 0;

  _Handle add(
    String id,
    DownloadTransportStatus status, {
    bool rehydrated = true,
  }) {
    final handle = _Handle(
      DownloadTransportSnapshot(taskId: id, status: status, progress: 0),
      () {
        if (rehydrated) recoveredIdReads++;
      },
    );
    handles[id] = handle;
    if (rehydrated) recovered.add(handle);
    return handle;
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async =>
      throw StateError('The startup fixture has no authorized transfer');

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async {
    lookupIds.add(taskId);
    return handles[taskId];
  }

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => recovered;

  @override
  Future<void> removeTracking(String taskId) async {
    removedIds.add(taskId);
    handles.remove(taskId);
  }
}

final class _Handle implements DownloadTransportHandle {
  _Handle(this.current, this.onRead);

  @override
  DownloadTransportSnapshot current;
  final void Function() onRead;
  int cancelCalls = 0;

  @override
  String get taskId {
    onRead();
    return current.taskId;
  }

  @override
  Stream<DownloadTransportSnapshot> get snapshots => const Stream.empty();

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    current = DownloadTransportSnapshot(
      taskId: current.taskId,
      status: DownloadTransportStatus.canceled,
      progress: 0,
    );
    return true;
  }

  @override
  Future<bool> pause() async => throw StateError('Unexpected pause');

  @override
  Future<bool> resume() async => throw StateError('Unexpected resume');
}
