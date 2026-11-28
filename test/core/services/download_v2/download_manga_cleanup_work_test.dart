import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_persistent_storage_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../support/manga_image_fixtures.dart';
import 'download_v2_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reopened manga cleanup keeps every exact child ownership fence', () async {
    final root = await Directory.systemTemp.createTemp('aw-manga-cleanup-');
    addTearDown(() => root.delete(recursive: true));
    final first = await _chapter(root, 'first', 1, 64);
    final second = await _chapter(root, 'second', 2, 4);
    final firstTasks = [for (var i = 1; i <= 64; i++) _page(first.taskId, i)];
    final secondTasks = [for (var i = 1; i <= 4; i++) _page(second.taskId, i)];
    final oldGeneration = _page(taskIdForGeneration(first.logicalId, 1), 1);
    final wrongGroup = _page(first.taskId, 65, group: 'unrelated-group');
    final malformed = _task('${first.taskId}_p0000');
    final unrelated = [
      for (var i = 0; i < 192; i++) _task('unrelated-$i'),
      ...secondTasks,
      oldGeneration,
      wrongGroup,
      malformed,
    ];

    final seeded = DownloadPersistenceWorker.forDirectory(root.path);
    addTearDown(seeded.close);
    final initialStore = HiveLogicalDownloadStoreV2(worker: seeded);
    await initialStore.put(first);
    await initialStore.put(second);
    final initialStorage = DownloadPersistentStorageV2(worker: seeded);
    for (final task in [...firstTasks, ...unrelated]) {
      await initialStorage.storeTaskRecord(_record(task));
    }
    await initialStorage.storePausedTask(firstTasks.first);
    await initialStorage.storeResumeData(
      ResumeData(firstTasks.first, 'first opaque checkpoint'),
    );
    await initialStorage.storeResumeData(
      ResumeData(secondTasks.first, 'untouched opaque checkpoint'),
    );
    // The persisted copy can have a different filename from its real task ID.
    // A duplicate status must still block cleanup even when that row is not
    // itself a member of either allowed selection group.
    const alias = 'legacy-running-alias';
    final aliasFile = File(
      p.join(root.path, DownloadPersistentStorageV2.taskRecordsPath, alias),
    );
    await aliasFile.writeAsString(
      jsonEncode(
        _record(
          _task(firstTasks.last.taskId, group: 'legacy-other-group'),
          TaskStatus.running,
        ).toJson(),
      ),
      flush: true,
    );
    await seeded.close();

    final worker = DownloadPersistenceWorker.forDirectory(root.path);
    addTearDown(worker.close);
    final store = HiveLogicalDownloadStoreV2(worker: worker);
    final storage = DownloadPersistentStorageV2(worker: worker);
    final downloader = _OfflineDownloader(storage)
      ..live.addAll([firstTasks.last, secondTasks.last]);
    addTearDown(downloader.database.destroy);
    final gateway = PackageBackgroundDownloaderGateway(
      downloader: downloader,
      initializePackage: storage.initialize,
      isIOS: () => false,
    );
    final resolver = StaticSourceResolverV2();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    addTearDown(manager.dispose);
    await manager.initialize();
    expect(resolver.calls, 0);
    for (final chapter in [first, second]) {
      final snapshot = manager.snapshotFor(chapter.logicalId)!;
      expect(snapshot.status, DownloadTransportStatus.complete);
      expect(
        snapshot.completedPages,
        chapter.logicalId == first.logicalId ? 64 : 4,
      );
      expect(snapshot.progress, 1);
    }
    expect(
      await downloader.database.recordForId(firstTasks.first.taskId),
      isNotNull,
    );
    expect(
      await downloader.database.recordForId(secondTasks.first.taskId),
      isNotNull,
    );

    downloader.live.remove(firstTasks.last);
    await expectLater(
      gateway.removeTracking(first.taskId),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'exact unsettled task',
          'Manga page ownership has not settled: ${firstTasks.last.taskId}',
        ),
      ),
    );
    expect(
      await storage.retrievePausedTask(firstTasks.first.taskId),
      isNotNull,
    );
    expect(
      await storage.retrieveResumeData(firstTasks.first.taskId),
      isNotNull,
    );
    await storage.removeTaskRecord(alias);
    await gateway.removeTracking(first.taskId);

    final retained = unrelated.map((task) => task.taskId).toSet();
    expect(
      (await downloader.database.allRecords()).map((r) => r.taskId),
      unorderedEquals(retained),
    );
    expect(await storage.retrievePausedTask(firstTasks.first.taskId), isNull);
    expect(await storage.retrieveResumeData(firstTasks.first.taskId), isNull);
    expect(
      (await storage.retrieveResumeData(secondTasks.first.taskId))?.data,
      'untouched opaque checkpoint',
    );
    expect(await manager.hasCompletedDownload(first.logicalId), isTrue);
    expect(await manager.hasCompletedDownload(second.logicalId), isTrue);
    expect(
      await File(p.join(first.destinationPath, '0064.png')).readAsBytes(),
      tinyMangaPng,
    );
    final durable = (await store.get(first.logicalId))!;
    expect(durable.completedAtMillis, first.completedAtMillis);
    expect(durable.taskId, first.taskId);
    await manager.dispose();
    await worker.close();

    final reopened = DownloadPersistenceWorker.forDirectory(root.path);
    addTearDown(reopened.close);
    final reopenedStorage = DownloadPersistentStorageV2(worker: reopened);
    final reopenedStore = HiveLogicalDownloadStoreV2(worker: reopened);
    expect(
      (await reopenedStorage.retrieveAllTaskRecords()).map((r) => r.taskId),
      unorderedEquals(retained),
    );
    expect((await reopenedStore.get(first.logicalId))?.completedAtMillis, 2);
    expect((await reopenedStore.get(second.logicalId))?.completedAtMillis, 2);
    print(
      'C26_MANGA_OUTCOME complete=64,4 retained=${retained.length} '
      'no-source=${resolver.calls} paused=removed alias=blocked reopened=exact',
    );
  });
}

Future<LogicalDownloadRecordV2> _chapter(
  Directory root,
  String chapter,
  int timestamp,
  int pages,
) async {
  final id = logicalDownloadIdForMangaChapter(
    mangaId: 'offline',
    chapterId: chapter,
  );
  final dir = await Directory(p.join(root.path, chapter)).create();
  final digest = sha256.convert(tinyMangaPng).toString();
  for (var i = 1; i <= pages; i++) {
    await File(p.join(dir.path, '${i.toString().padLeft(4, '0')}.png'))
        .writeAsBytes(tinyMangaPng, flush: true);
  }
  await MangaChapterManifestV2(
    version: MangaChapterManifestV2.currentVersion,
    mangaId: 'offline',
    chapterId: chapter,
    pageCount: pages,
    completedIndexes: {for (var i = 0; i < pages; i++) i},
    pageDigests: {for (var i = 0; i < pages; i++) i: digest},
    isComplete: true,
  ).writeTo(dir);
  return LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: id,
    mediaKind: DownloadMediaKind.mangaChapter,
    mediaId: 'offline',
    unitKey: chapter,
    variantKey: 'pages',
    generation: 2,
    taskId: taskIdForGeneration(id, 2),
    intent: DownloadUserIntent.active,
    destinationPath: dir.path,
    sourceDescriptor: const {},
    updatedAtMillis: timestamp,
    completedAtMillis: 2,
  );
}

DownloadTask _task(String id, {String group = kDownloadV2SilentPackageGroup}) =>
    DownloadTask(
      taskId: id,
      group: group,
      url: 'https://example.invalid/no-network',
      filename: '$id.png',
    );

DownloadTask _page(String parent, int page, {String? group}) => _task(
  '${parent}_p${page.toString().padLeft(4, '0')}',
  group:
      group ??
      (page.isEven ? kDownloadV2PackageGroup : kDownloadV2SilentPackageGroup),
);

TaskRecord _record(
  DownloadTask task, [
  TaskStatus status = TaskStatus.complete,
]) => TaskRecord(task, status, status == TaskStatus.complete ? 1 : .5, 5);

final class _OfflineDownloader implements FileDownloader {
  _OfflineDownloader(PersistentStorage storage) : database = Database(storage);

  @override
  final Database database;
  @override
  final Transfers transfers = _OfflineTransfers();
  final live = <Task>[];

  @override
  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) async => [...live];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _OfflineTransfers implements Transfers {
  @override
  Transfer? forId(String taskId) => null;

  @override
  Future<List<Transfer>> rehydrateFromDatabase({String? group}) async => [];

  @override
  Transfer? remove(String taskId, {bool dispose = true}) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
