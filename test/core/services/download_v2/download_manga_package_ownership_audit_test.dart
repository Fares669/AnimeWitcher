import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_transport_v2.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../support/manga_image_fixtures.dart';
import 'download_v2_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final intent in [DownloadUserIntent.paused, DownloadUserIntent.canceled]) {
    test('offline $intent manga startup controls its persisted child without a parent record', () async {
      final f = await _Fixture.create(intent: intent);
      addTearDown(f.dispose);
      f.resolver.fail = true;
      final child = await f.addPage(1, TaskStatus.running);
      await f.manager.initialize();
      expect(f.resolver.calls, 0);
      expect(f.downloader.testTransfers.started, isEmpty);
      expect(f.downloader.transfers.forId(child.taskId)?.status,
          intent == DownloadUserIntent.paused ? TaskStatus.paused : anyOf(isNull, TaskStatus.canceled));
      expect(intent == DownloadUserIntent.paused
          ? f.downloader.pausedIds : f.downloader.canceledIds, contains(child.taskId));
      expect((await f.store.get(f.logicalId))?.generation, 3);
      expect((await f.store.get(f.logicalId))?.taskId, f.parentId);
      expect(await File(p.join(f.directory.path, '0001.png')).readAsBytes(), tinyMangaPng);
    });
  }

  test('rejected recovered manga pause keeps live ownership admitted', () async {
    final f = await _Fixture.create(intent: DownloadUserIntent.paused, limit: 1);
    addTearDown(f.dispose);
    final child = await f.addPage(1, TaskStatus.running);
    f.downloader.rejectPause = true;
    f.resolver.fail = true;
    await f.manager.initialize();
    expect(f.manager.snapshotFor(f.logicalId)?.status, DownloadTransportStatus.running);
    expect(f.downloader.transfers.forId(child.taskId)!.status, TaskStatus.running);
    expect(f.downloader.pausedIds, contains(child.taskId));
    final waiting = await f.manager.start(_videoRequest(f.directory.path));
    expect(waiting.status, DownloadTransportStatus.queued);
    expect(f.downloader.testTransfers.started, isEmpty);
    expect((await f.store.get(f.logicalId))?.intent, DownloadUserIntent.paused);
  });

  test('failed manga resolver retains recovered running truth and admission', () async {
    final f = await _Fixture.create(limit: 1);
    addTearDown(f.dispose);
    final child = await f.addPage(1, TaskStatus.running);
    f.resolver.fail = true;
    await f.manager.initialize();
    expect(f.resolver.calls, 1);
    expect(f.manager.snapshotFor(f.logicalId)?.status,
        anyOf(DownloadTransportStatus.running, DownloadTransportStatus.held));
    expect((await f.store.get(f.logicalId))?.intent, DownloadUserIntent.active);
    expect((await f.store.get(f.logicalId))?.completedAtMillis, isNull);
    expect(f.downloader.transfers.forId(child.taskId)!.status, TaskStatus.running);
    expect((await f.manager.start(_videoRequest(f.directory.path))).status, DownloadTransportStatus.queued);
    expect(f.downloader.testTransfers.started, isEmpty);
  });

  test('Retry after failed manga reconstruction settles the old child before generation four', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final child = await f.addPage(1, TaskStatus.running);
    f.resolver.fail = true;
    await f.manager.initialize();
    f.resolver.fail = false;
    await f.manager.restart(f.logicalId);
    await _until(() async => f.downloader.testTransfers.started.any((task) => task.taskId.endsWith('_g4_p0002')));
    expect(f.downloader.canceledIds, contains(child.taskId));
    expect(f.downloader.overlappingPaths, isEmpty);
    expect((await f.store.get(f.logicalId))?.generation, 4);
    expect((await f.store.get(f.logicalId))?.taskId, taskIdForGeneration(f.logicalId, 4));
    expect(await File(p.join(f.directory.path, '0001.png')).readAsBytes(), tinyMangaPng);
  });

  test('full manga reconstruction reuses exact current children without canceling page bytes', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final child = await f.addPage(1, TaskStatus.running);
    await f.manager.initialize();
    await _until(() async => f.manager.snapshotFor(f.logicalId)?.activeConnections == 1);
    expect(f.resolver.calls, 1);
    expect((await f.store.get(f.logicalId))?.generation, 3);
    expect((await f.store.get(f.logicalId))?.taskId, f.parentId);
    expect(f.downloader.canceledIds, isEmpty);
    expect(f.downloader.testTransfers.started, isEmpty);
    expect(f.downloader.transfers.forId(child.taskId)!.status, TaskStatus.running);
    expect(await File(p.join(f.directory.path, '0001.png')).readAsBytes(), tinyMangaPng);
    expect((await MangaChapterManifestV2.readFrom(f.directory))?.completedIndexes, {0});
  });

  test('a recovered completed child subset never publishes a completed chapter offline', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    await f.addPage(0, TaskStatus.complete);
    f.resolver.fail = true;
    await f.manager.initialize();
    expect((await f.store.get(f.logicalId))?.completedAtMillis, isNull);
    expect(f.manager.snapshotFor(f.logicalId)?.status, isNot(DownloadTransportStatus.complete));
    expect(await f.manager.hasCompletedDownload(f.logicalId), isFalse);
    expect((await MangaChapterManifestV2.readFrom(f.directory))?.isComplete, isFalse);
    expect(await File(p.join(f.directory.path, '0001.png')).readAsBytes(), tinyMangaPng);
  });

  test('package manga cleanup removes only exact terminal children and their recovery tracking', () async {
    final f = await _Fixture.create(intent: DownloadUserIntent.paused);
    addTearDown(f.dispose);
    final selected = <DownloadTask>[
      await f.addPage(0, TaskStatus.complete),
      await f.addPage(1, TaskStatus.canceled, group: kDownloadV2PackageGroup),
    ];
    final otherId = taskIdForGeneration(
      logicalDownloadIdForMangaChapter(mangaId: 'other', chapterId: 'chapter'), 3,
    );
    final retained = <DownloadTask>[
      await f.addPage(0, TaskStatus.complete, parentId: otherId),
      await f.addTask('${f.parentId}_p0001_extra', TaskStatus.complete),
      await f.addTask('${f.parentId}_p0000', TaskStatus.complete),
      await f.addTask(taskIdForGeneration(_videoRequest(f.directory.path).logicalId, 1), TaskStatus.complete),
      await f.addTask('unrelated', TaskStatus.complete,
          metadata: jsonEncode({'parentTaskId': f.parentId})),
    ];
    for (final task in [...selected, ...retained]) {
      f.downloader.storage.paused[task.taskId] = task;
      f.downloader.storage.resume[task.taskId] = ResumeData(task, 'saved-${task.taskId}');
    }
    final childHandle = (await f.gateway.attach(selected.first.taskId))!;
    var observerClosed = false;
    final subscription = childHandle.snapshots.listen((_) {}, onDone: () => observerClosed = true);
    addTearDown(subscription.cancel);
    await f.gateway.removeTracking(f.parentId);
    expect(f.downloader.storage.records.keys, unorderedEquals(retained.map((task) => task.taskId)));
    expect(f.downloader.storage.paused.keys, unorderedEquals(retained.map((task) => task.taskId)));
    expect(f.downloader.storage.resume.keys, unorderedEquals(retained.map((task) => task.taskId)));
    expect(f.downloader.testTransfers.handles.keys, unorderedEquals(retained.map((task) => task.taskId)));
    await _until(() async => observerClosed);
    expect((await MangaChapterManifestV2.readFrom(f.directory))?.completedIndexes, {0});
    for (final task in selected) {
      expect(await File(await task.filePath()).readAsBytes(), tinyMangaPng);
    }
    // Repeated parent generations cannot accumulate terminal transport rows.
    for (var generation = 4; generation <= 6; generation++) {
      final parent = taskIdForGeneration(f.logicalId, generation);
      final task = await f.addPage(1, TaskStatus.complete, parentId: parent);
      f.downloader.storage.paused[task.taskId] = task;
      f.downloader.storage.resume[task.taskId] = ResumeData(task, 'saved');
      await f.gateway.removeTracking(parent);
      expect(f.downloader.storage.records, hasLength(retained.length));
      expect(f.downloader.storage.paused, hasLength(retained.length));
      expect(f.downloader.storage.resume, hasLength(retained.length));
      expect(f.downloader.testTransfers.handles, hasLength(retained.length));
    }
  });

  test('package manga cleanup rejects unresolved live children and preserves their files', () async {
    final f = await _Fixture.create(intent: DownloadUserIntent.paused);
    addTearDown(f.dispose);
    final child = await f.addPage(1, TaskStatus.running);
    await expectLater(f.gateway.removeTracking(f.parentId), throwsStateError);
    expect(f.downloader.storage.records, contains(child.taskId));
    expect(f.downloader.transfers.forId(child.taskId)?.status, TaskStatus.running);
    expect(await File(await child.filePath()).readAsBytes(), tinyMangaPng);
    expect(await MangaChapterManifestV2.readFrom(f.directory), isNotNull);
  });

  test('completed package HTML child is rejected before fresh-page reuse', () async {
    final f = await _Fixture.create(intent: DownloadUserIntent.paused);
    addTearDown(f.dispose);
    final child = await f.addPage(1, TaskStatus.complete);
    final file = File(await child.filePath());
    final html = utf8.encode('<html>HTTP200 login</html>');
    await file.writeAsBytes(html);
    var removed = false;
    final reusable = await reusableMangaPageHandleV2(
      existing: await f.gateway.attach(child.taskId), destinationPath: file.path,
      removeTracking: () async {
        removed = true;
        await f.gateway.removeTracking(child.taskId);
      },
    );
    expect(reusable, isNull);
    expect(removed, isTrue);
    expect(await file.readAsBytes(), html);
  });
}

DownloadStartRequestV2 _videoRequest(String root) {
  return DownloadStartRequestV2(
    logicalId: logicalDownloadIdFor(animeId: 'waiting', episodeKey: '1', variantKey: 'sub'),
    mediaId: 'waiting', unitKey: '1', variantKey: 'sub',
    destinationPath: p.join(root, 'waiting.mp4'), sourceDescriptor: const {},
    allowPause: true, retries: 1, parallelChunks: 1,
  );
}

Future<void> _until(Future<bool> Function() done) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('expected package ownership condition was not reached');
}

final class _Fixture {
  _Fixture(this.directory, this.downloader, {required DownloadUserIntent intent, required int limit}) {
    parentId = taskIdForGeneration(logicalId, 3);
    gateway = PackageBackgroundDownloaderGateway(
      downloader: downloader, initializePackage: () async {}, isIOS: () => false,
      notificationPreferences: () => DownloadNotificationPrefs.disabled,
    );
    manager = DownloadManagerV2(
      store: store, gateway: gateway, sourceResolver: StaticSourceResolverV2(),
      mangaChapterPageResolver: resolver, maxConcurrentDownloads: () => limit,
    );
    record = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: logicalId, mediaKind: DownloadMediaKind.mangaChapter,
      mediaId: 'manga-package', unitKey: 'chapter', variantKey: 'pages',
      generation: 3, taskId: parentId, intent: intent,
      destinationPath: directory.path, sourceDescriptor: const {}, updatedAtMillis: 1,
    );
  }
  final Directory directory;
  final _Downloader downloader;
  final store = InMemoryLogicalDownloadStoreV2();
  final resolver = _Resolver();
  final logicalId = logicalDownloadIdForMangaChapter(mangaId: 'manga-package', chapterId: 'chapter');
  late final String parentId;
  late final LogicalDownloadRecordV2 record;
  late final PackageBackgroundDownloaderGateway gateway;
  late final DownloadManagerV2 manager;

  static Future<_Fixture> create({DownloadUserIntent intent = DownloadUserIntent.active, int limit = 10}) async {
    final directory = await Directory.systemTemp.createTemp('aw-manga-package-owner-');
    final f = _Fixture(directory, _Downloader(), intent: intent, limit: limit);
    await File(p.join(directory.path, '0001.png')).writeAsBytes(tinyMangaPng);
    await MangaChapterManifestV2(
      version: 1, mangaId: 'manga-package', chapterId: 'chapter', pageCount: 2,
      completedIndexes: const {0}, isComplete: false,
    ).writeTo(directory);
    await f.store.put(f.record);
    return f;
  }

  Future<DownloadTask> addPage(int index, TaskStatus status, {String? parentId, String group = kDownloadV2SilentPackageGroup}) =>
      addTask('${parentId ?? this.parentId}_p${(index + 1).toString().padLeft(4, '0')}', status,
          filename: '${(index + 1).toString().padLeft(4, '0')}.png', group: group);

  Future<DownloadTask> addTask(String id, TaskStatus status, {
    String? filename, String group = kDownloadV2SilentPackageGroup, String metadata = '',
  }) async {
    final task = DownloadTask(
      taskId: id, url: 'https://example.test/$id.png', filename: filename ?? '$id.png',
      directory: directory.path, baseDirectory: BaseDirectory.root,
      group: group, metaData: metadata, allowPause: true, updates: Updates.statusAndProgress,
    );
    await File(await task.filePath()).writeAsBytes(tinyMangaPng);
    await downloader.database.updateRecord(TaskRecord(task, status, .5, tinyMangaPng.length));
    downloader.testTransfers.adopt(task, status);
    return task;
  }

  Future<void> dispose() async {
    downloader.rejectPause = false;
    for (final saved in await store.all()) {
      try {
        await manager.cancel(saved.logicalId);
      } catch (_) {}
    }
    await manager.dispose();
    for (final transfer in downloader.testTransfers.handles.values.toList()) {
      await downloader.cancelTaskWithId(transfer.taskId);
      await gateway.removeTracking(transfer.taskId);
    }
    await downloader.updatesController.close();
    downloader.database.destroy();
    await directory.delete(recursive: true);
  }
}

final class _Resolver implements MangaChapterPageResolverV2 {
  bool fail = false;
  int calls = 0;
  @override
  Future<List<MangaPage>> resolve(Map<String, Object?> descriptor) async {
    calls++;
    if (fail) throw StateError('offline page resolver');
    return const [
      MangaPage(index: 0, imageUrl: 'https://example.test/0001.png'),
      MangaPage(index: 1, imageUrl: 'https://example.test/0002.png'),
    ];
  }
}

final class _Downloader implements FileDownloader {
  _Downloader() : database = Database(_Storage()) {
    transfers = _Transfers(this);
  }
  @override
  final Database database;
  _Storage get storage => database.storage as _Storage;
  @override
  late Transfers transfers;
  _Transfers get testTransfers => transfers as _Transfers;
  final updatesController = StreamController<TaskUpdate>.broadcast();
  final pausedIds = <String>[];
  final canceledIds = <String>[];
  final overlappingPaths = <String>[];
  bool rejectPause = false;
  @override
  Stream<TaskUpdate> get updates => updatesController.stream;
  @override
  Future<bool> pause(DownloadTask task) async {
    pausedIds.add(task.taskId);
    if (rejectPause) return false;
    storage.paused[task.taskId] = task;
    await _status(task.taskId, TaskStatus.paused);
    return true;
  }
  @override
  Future<bool> resume(DownloadTask task) async {
    storage.paused.remove(task.taskId);
    await _status(task.taskId, TaskStatus.running);
    return true;
  }
  @override
  Future<bool> cancelTaskWithId(String taskId) async {
    canceledIds.add(taskId);
    storage.paused.remove(taskId);
    await _status(taskId, TaskStatus.canceled);
    return true;
  }
  Future<void> _status(String id, TaskStatus status) async {
    final transfer = transfers.forId(id);
    final task = transfer?.task ?? storage.records[id]?.task;
    if (task == null) return;
    await database.updateRecord(TaskRecord(task, status, .5, tinyMangaPng.length));
    final update = TaskStatusUpdate(task, status);
    transfer?.updateStatus(update);
    updatesController.add(update);
  }
  @override
  Future<List<Task>> allTasks({String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true, bool allGroups = false,
  }) async => [
    for (final record in storage.records.values)
      if ((allGroups || record.task.group == group) &&
          [TaskStatus.enqueued, TaskStatus.running, TaskStatus.waitingToRetry].contains(record.status)) record.task,
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transfers implements Transfers {
  _Transfers(this.downloader);
  @override
  final _Downloader downloader;
  final handles = <String, Transfer>{};
  final started = <Task>[];
  void adopt(Task task, TaskStatus status) {
    final transfer = handles.putIfAbsent(task.taskId, () => Transfer(task, downloader));
    transfer.updateStatus(TaskStatusUpdate(task, status));
  }
  @override
  Transfer? forId(String taskId) => handles[taskId];
  @override
  Future<List<Transfer>> rehydrateFromDatabase({String? group}) async => [
    for (final transfer in handles.values)
      if (group == null || transfer.task.group == group) transfer,
  ];
  @override
  Future<Transfer> start(Task task) async {
    final destination = await task.filePath();
    for (final live in await downloader.allTasks(allGroups: true)) {
      if (live.taskId != task.taskId && await live.filePath() == destination) {
        downloader.overlappingPaths.add(destination);
      }
    }
    started.add(task);
    await downloader.database.updateRecord(TaskRecord(task, TaskStatus.running, 0, -1));
    adopt(task, TaskStatus.running);
    return handles[task.taskId]!;
  }
  @override
  Transfer? remove(String taskId, {bool dispose = true}) {
    final transfer = handles.remove(taskId);
    if (dispose) transfer?.dispose();
    return transfer;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Storage implements PersistentStorage {
  final records = <String, TaskRecord>{};
  final paused = <String, Task>{};
  final resume = <String, ResumeData>{};
  @override
  Future<void> storeTaskRecord(TaskRecord record) async { records[record.taskId] = record; }
  @override
  Future<TaskRecord?> retrieveTaskRecord(String id) async => records[id];
  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async => records.values.toList();
  @override
  Future<void> removeTaskRecord(String? id) async {
    if (id == null) { records.clear(); } else { records.remove(id); }
  }
  @override
  Future<void> storePausedTask(Task task) async { paused[task.taskId] = task; }
  @override
  Future<Task?> retrievePausedTask(String id) async => paused[id];
  @override
  Future<List<Task>> retrieveAllPausedTasks() async => paused.values.toList();
  @override
  Future<void> removePausedTask(String? id) async {
    if (id == null) { paused.clear(); } else { paused.remove(id); }
  }
  @override
  Future<void> storeResumeData(ResumeData data) async { resume[data.taskId] = data; }
  @override
  Future<ResumeData?> retrieveResumeData(String id) async => resume[id];
  @override
  Future<List<ResumeData>> retrieveAllResumeData() async => resume.values.toList();
  @override
  Future<void> removeResumeData(String? id) async {
    if (id == null) { resume.clear(); } else { resume.remove(id); }
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
