import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_persistent_storage_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// Use private filesystem directories without opening platform services.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'download_v2_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'verified Downloads startup keeps neighboring package records',
    () async {
      final f = await _fixture();
      const rowCount = 12;
      const unrelatedCount = 18;
      final rows = <LogicalDownloadRecordV2>[];
      for (var index = 0; index < rowCount; index++) {
        rows.add(await f.save(index));
      }
      final unrelated = <String>[];
      for (var index = 0; index < unrelatedCount; index++) {
        final task = _packageTask('unrelated-$index');
        await f.db.updateRecord(_completed(task));
        unrelated.add(task.taskId);
      }
      for (final row in rows.take(rowCount ~/ 3)) {
        await f.db.updateRecord(_completed(_packageTask(row.taskId)));
      }
      // Both verified local files with package metadata and ones whose tracking
      // is already gone must retain exactly the same downloaded state.
      final shown = await f.manager.records.first;
      await f.manager.initialize();

      final ids = (await f.db.allRecords()).map((r) => r.taskId).toSet();
      expect(ids, equals(unrelated.toSet()));
      expect(
        shown.map((row) => row.logicalId),
        unorderedEquals(rows.map((r) => r.logicalId)),
      );
      for (final row in rows) {
        expect(
          f.manager.snapshotFor(row.logicalId)?.status,
          DownloadTransportStatus.complete,
        );
        expect(await File(row.destinationPath).readAsBytes(), [
          0,
          17,
          255,
          8,
          row.updatedAtMillis - 1,
        ]);
      }
      expect(f.resolver.calls, 0);
    },
  );

  test(
    'fresh metadata-owned children keep their native ownership fence',
    () async {
      final f = await _fixture();
      final parent = (await f.save(0)).taskId;
      final other = (await f.save(1)).taskId;
      final foreign = _durable('foreign-alias', other);

      // Trigger an absent-parent lookup, then add a range through the same
      // serialized store. Database state cannot be cached as an empty answer.
      await f.gateway.removeTracking(parent);
      final writer = _durable('$parent.part.7', parent);
      final metadataOnly = _durable(
        'legacy-child-without-parent-prefix',
        parent,
      );
      await f.db.updateRecord(_completed(writer));
      await f.db.updateRecord(_completed(metadataOnly));
      await f.db.updateRecord(_completed(foreign));
      await f.storage.storePausedTask(metadataOnly);
      await f.storage.storeResumeData(
        ResumeData(metadataOnly, 'retained resume'),
      );
      f.downloader.live.add(writer);
      await expectLater(f.gateway.removeTracking(parent), throwsStateError);
      expect(await f.db.recordForId(writer.taskId), isNotNull);
      expect(await f.db.recordForId(metadataOnly.taskId), isNotNull);
      expect(
        await f.storage.retrieveResumeData(metadataOnly.taskId),
        isNotNull,
      );
      f.downloader.live.clear();
      final lateChild = _durable('after-native-inventory', parent);
      f.downloader.onInventory = () => f.db.updateRecord(_completed(lateChild));
      await f.gateway.removeTracking(parent);
      expect(await f.db.recordForId(lateChild.taskId), isNull);
      expect(await f.db.recordForId(writer.taskId), isNull);
      expect(await f.db.recordForId(metadataOnly.taskId), isNull);
      expect(await f.storage.retrievePausedTask(metadataOnly.taskId), isNull);
      expect(await f.storage.retrieveResumeData(metadataOnly.taskId), isNull);
      expect(await f.db.recordForId(foreign.taskId), isNotNull);
      expect(
        await File((await f.store.all()).first.destinationPath).exists(),
        isTrue,
      );
    },
  );

  test(
    'durable child replacement and collection reset select exact owner',
    () async {
      final f = await _fixture();
      final parent = (await f.save(0)).taskId;
      final other = (await f.save(1)).taskId;
      // The existing persisted group and metadata, not its filename or case
      // spelling, establish ownership on the worker's first full scan.
      final legacy = _durable('LegacyChild', parent);
      await f.db.updateRecord(_completed(legacy));
      // An unrelated parent triggers the first lookup without removing legacy.
      await f.gateway.removeTracking('unknown-parent');
      await f.db.updateRecord(_completed(_durable(legacy.taskId, other)));
      await f.gateway.removeTracking(parent);
      expect(await f.db.recordForId(legacy.taskId), isNotNull);
      await f.gateway.removeTracking(other);
      expect(await f.db.recordForId(legacy.taskId), isNull);

      final lowerCaseChild = _durable('changing-owner', parent);
      await f.db.updateRecord(_completed(lowerCaseChild));
      await f.gateway.removeTracking('warm-owning-index');
      // Replacement switches both fresh owner lookup and later deletion.
      await f.db.updateRecord(
        _completed(_durable(lowerCaseChild.taskId, other)),
      );
      await f.gateway.removeTracking(parent);
      expect(await f.db.recordForId(lowerCaseChild.taskId), isNotNull);
      await f.gateway.removeTracking(other);
      expect(await f.db.recordForId(lowerCaseChild.taskId), isNull);

      final removed = _durable('cleared-child', parent);
      await f.db.updateRecord(_completed(removed));
      await f.db.deleteAllRecords();
      final ordinary = _packageTask(removed.taskId);
      await f.db.updateRecord(_completed(ordinary));
      await f.gateway.removeTracking(parent);
      expect(await f.db.recordForId(ordinary.taskId), isNotNull);
    },
  );
  test(
    'first lookup sees metadata-owned files migrated from Documents',
    () async {
      const parent = 'legacy-video-parent';
      final legacy = _durable('legacy-path-does-not-start-with-parent', parent);
      final fixture = await _fixture(migrating: _completed(legacy));
      await fixture.gateway.removeTracking(parent);
      expect(await fixture.db.recordForId(legacy.taskId), isNull);
      expect(await fixture.db.allRecords(), isEmpty);
      expect(
        await File(
          p.join(
            fixture.root.path,
            'Documents',
            DownloadPersistentStorageV2.taskRecordsPath,
            legacy.taskId,
          ),
        ).exists(),
        isFalse,
      );
    },
  );
}

TaskRecord _completed(DownloadTask task) =>
    TaskRecord(task, TaskStatus.complete, 1, 5);

DownloadTask _packageTask(
  String id, {
  String group = kDownloadV2PackageGroup,
  String metadata = '',
}) => DownloadTask(
  taskId: id,
  group: group,
  url: 'https://example.invalid/no-network',
  filename: '$id.mp4',
  metaData: metadata,
);

DownloadTask _durable(String id, String parent) => _packageTask(
  id,
  group: kPersistentDownloadChunkGroup,
  metadata: jsonEncode({'parentTaskId': ' $parent '}),
);

Future<_Fixture> _fixture({TaskRecord? migrating}) async {
  final root = await Directory.systemTemp.createTemp('aw-package-tracking-');
  final oldPaths = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _Paths(root.path);
  final documents = Directory(p.join(root.path, 'Documents'));
  if (migrating != null) {
    final file = File(
      p.join(
        documents.path,
        DownloadPersistentStorageV2.taskRecordsPath,
        migrating.taskId,
      ),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(migrating.toJson()));
  }
  final worker = DownloadPersistenceWorker.forDirectory(
    root.path,
    documentsDirectory: documents.path,
  );
  final storage = DownloadPersistentStorageV2(worker: worker);
  final downloader = _OfflineDownloader(storage);
  final gateway = PackageBackgroundDownloaderGateway(
    downloader: downloader,
    initializePackage: storage.initialize,
    isIOS: () => false,
  );
  final store = InMemoryLogicalDownloadStoreV2();
  final resolver = StaticSourceResolverV2();
  final manager = DownloadManagerV2(
    store: store,
    gateway: gateway,
    sourceResolver: resolver,
  );
  addTearDown(() async {
    await manager.dispose();
    downloader.database.destroy();
    await worker.close();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });
  return _Fixture(root, storage, downloader, gateway, store, resolver, manager);
}

final class _Fixture {
  _Fixture(
    this.root,
    this.storage,
    this.downloader,
    this.gateway,
    this.store,
    this.resolver,
    this.manager,
  );
  final Directory root;
  final DownloadPersistentStorageV2 storage;
  final _OfflineDownloader downloader;
  final PackageBackgroundDownloaderGateway gateway;
  final InMemoryLogicalDownloadStoreV2 store;
  final StaticSourceResolverV2 resolver;
  final DownloadManagerV2 manager;
  Database get db => downloader.database;

  Future<LogicalDownloadRecordV2> save(int index) async {
    final logicalId = logicalDownloadIdFor(
      animeId: 'offline-package-tracking',
      episodeKey: '$index',
      variantKey: 'fixture',
    );
    final path = p.join(root.path, 'video-$index.mp4');
    await File(path).writeAsBytes([0, 17, 255, 8, index]);
    final row = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: logicalId,
      mediaId: 'offline-package-tracking',
      unitKey: '$index',
      variantKey: 'fixture',
      generation: 1,
      taskId: taskIdForGeneration(logicalId, 1),
      intent: DownloadUserIntent.active,
      destinationPath: path,
      sourceDescriptor: const {'providerId': 'offline-fixture'},
      updatedAtMillis: index + 1,
      completedAtMillis: index + 1,
      expectedBytes: 5,
    );
    await store.put(row);
    return row;
  }
}

final class _OfflineDownloader implements FileDownloader {
  _OfflineDownloader(PersistentStorage storage) : database = Database(storage);
  @override
  final Database database;
  @override
  final Transfers transfers = _Transfers();
  final live = <Task>[];
  Future<void> Function()? onInventory;

  @override
  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) async {
    final listener = onInventory;
    onInventory = null;
    await listener?.call();
    return [...live];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transfers implements Transfers {
  @override
  Transfer? forId(String taskId) => null;
  @override
  Future<List<Transfer>> rehydrateFromDatabase({String? group}) async => [];
  @override
  Transfer? remove(String taskId, {bool dispose = true}) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getDownloadsPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}
