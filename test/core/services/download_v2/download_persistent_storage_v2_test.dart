import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/download_persistent_storage_v2.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// The extensionless, flattened task JSON used by background_downloader 9.6.2.
// Keep this independent of the adapter's serializers to catch layout changes.
const _legacyTaskJson = '''
{
  "url": "https://example.invalid/episode.mp4",
  "headers": {"Accept": "video/mp4"},
  "httpRequestMethod": "GET",
  "post": null,
  "retries": 2,
  "retriesRemaining": 1,
  "creationTime": 1700000000000,
  "taskId": "legacy/task:1",
  "filename": "episode.mp4",
  "directory": "downloads",
  "baseDirectory": 2,
  "group": "anime-downloads",
  "updates": 3,
  "requiresWiFi": false,
  "allowPause": true,
  "priority": 5,
  "metaData": "legacy-metadata",
  "displayName": "Episode 1",
  "options": null,
  "taskType": "DownloadTask"
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory support;
  late Directory documents;
  late DownloadPersistenceWorker worker;
  late DownloadPersistentStorageV2 storage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download-storage-v2-');
    support = await Directory(p.join(root.path, 'support')).create();
    documents = await Directory(p.join(root.path, 'documents')).create();
    worker = DownloadPersistenceWorker.forDirectory(
      support.path,
      documentsDirectory: documents.path,
    );
    storage = DownloadPersistentStorageV2(worker: worker);
  });

  tearDown(() async {
    await worker.close();
    await root.delete(recursive: true);
  });

  Future<void> reopen() async {
    await worker.close();
    worker = DownloadPersistenceWorker.forDirectory(
      support.path,
      documentsDirectory: documents.path,
    );
    storage = DownloadPersistentStorageV2(worker: worker);
  }

  DownloadTask task(String id, {String metadata = ''}) => DownloadTask(
    taskId: id,
    url: 'https://example.invalid/episode.mp4',
    filename: 'episode.mp4',
    allowPause: true,
    metaData: metadata,
    creationTime: DateTime.fromMillisecondsSinceEpoch(1700000000000),
  );

  Future<void> writeJson(
    Directory directory,
    String collection,
    String id,
    Map<String, dynamic> json,
  ) async {
    final file = File(p.join(directory.path, collection, id));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(json), flush: true);
  }

  Future<void> seedLegacy(Directory directory) async {
    final json = jsonDecode(_legacyTaskJson) as Map<String, dynamic>;
    await writeJson(
      directory,
      'backgroundDownloaderPausedTasks',
      'legacy_task_1',
      json,
    );
    await writeJson(
      directory,
      'backgroundDownloaderTaskRecords',
      'legacy_task_1',
      {
        ...json,
        'status': 7,
        'progress': 0.25,
        'expectedFileSize': 4096,
        'exception': null,
      },
    );
    await writeJson(
      directory,
      'backgroundDownloaderResumeData',
      'legacy_task_1',
      {
        'task': json,
        'data': p.join(root.path, 'partial-download'),
        'requiredStartByte': 1024,
        'eTag': 'legacy-etag',
      },
    );
  }

  Future<void> expectLegacyRecords() async {
    final record = await storage.retrieveTaskRecord('legacy/task:1');
    expect(record, isNotNull);
    expect(record!.status, TaskStatus.paused);
    expect(record.progress, 0.25);
    expect(record.expectedFileSize, 4096);
    expect(record.task.toJson(), jsonDecode(_legacyTaskJson));
    final paused = await storage.retrievePausedTask('legacy/task:1');
    expect(paused!.toJson(), jsonDecode(_legacyTaskJson));
    final resume = await storage.retrieveResumeData('legacy/task:1');
    expect(resume!.task.toJson(), jsonDecode(_legacyTaskJson));
    expect(resume.requiredStartByte, 1024);
    expect(resume.eTag, 'legacy-etag');
    expect(await storage.retrieveAllTaskRecords(), [record]);
    expect(await storage.retrieveAllPausedTasks(), [paused]);
    expect(await storage.retrieveAllResumeData(), [resume]);
  }

  test(
    'preserves the package Localstore version and collection names',
    () async {
      expect(storage.currentDatabaseVersion, ('Localstore', 1));
      expect(await storage.storedDatabaseVersion, ('Localstore', 0));
      expect(
        DownloadPersistentStorageV2.taskRecordsPath,
        LocalStorePersistentStorage.taskRecordsPath,
      );
      expect(
        DownloadPersistentStorageV2.pausedTasksPath,
        LocalStorePersistentStorage.pausedTasksPath,
      );
      expect(
        DownloadPersistentStorageV2.resumeDataPath,
        LocalStorePersistentStorage.resumeDataPath,
      );
      await storage.initialize();
      expect(await storage.storedDatabaseVersion, ('Localstore', 1));
      expect(
        jsonDecode(
          await File(
            p.join(support.path, 'backgroundDownloaderDatabase', 'metaData'),
          ).readAsString(),
        ),
        {'version': 1},
      );
    },
  );

  test('reads existing extensionless v1 JSON and survives reopening', () async {
    await seedLegacy(support);
    await writeJson(support, 'backgroundDownloaderDatabase', 'metaData', {
      'version': 1,
    });
    await expectLegacyRecords();
    await reopen();
    await expectLegacyRecords();
  });

  test('migrates existing v0 documents into the same support layout', () async {
    await seedLegacy(documents);
    await expectLegacyRecords();
    expect(await storage.storedDatabaseVersion, ('Localstore', 1));
    for (final path in [
      DownloadPersistentStorageV2.taskRecordsPath,
      DownloadPersistentStorageV2.pausedTasksPath,
      DownloadPersistentStorageV2.resumeDataPath,
    ]) {
      expect(await Directory(p.join(documents.path, path)).exists(), isFalse);
      expect(
        await File(p.join(support.path, path, 'legacy_task_1')).exists(),
        isTrue,
      );
    }
    await reopen();
    await expectLegacyRecords();
  });

  test('ignores empty and malformed legacy rows beside valid JSON', () async {
    await seedLegacy(support);
    await writeJson(support, 'backgroundDownloaderDatabase', 'metaData', {
      'version': 1,
    });
    for (final collection in [
      DownloadPersistentStorageV2.taskRecordsPath,
      DownloadPersistentStorageV2.pausedTasksPath,
      DownloadPersistentStorageV2.resumeDataPath,
    ]) {
      await File(p.join(support.path, collection, 'empty')).writeAsString('');
      await File(p.join(support.path, collection, 'invalid'))
          .writeAsString('{');
      await File(p.join(support.path, collection, 'not-a-map'))
          .writeAsString('[]');
    }
    for (final id in ['empty', 'invalid', 'not-a-map']) {
      expect(await storage.retrieveTaskRecord(id), isNull);
      expect(await storage.retrievePausedTask(id), isNull);
      expect(await storage.retrieveResumeData(id), isNull);
    }
    await expectLegacyRecords();
    await reopen();
    await expectLegacyRecords();
  });

  test('empty legacy metadata still triggers v0 migration', () async {
    await seedLegacy(documents);
    final metadata = File(
      p.join(support.path, 'backgroundDownloaderDatabase', 'metaData'),
    );
    await metadata.parent.create(recursive: true);
    await metadata.writeAsString('');
    await expectLegacyRecords();
    expect(await storage.storedDatabaseVersion, ('Localstore', 1));
    expect(jsonDecode(await metadata.readAsString()), {'version': 1});
  });

  test(
    'rejects a symlink migration root without touching its target',
    () async {
      final external = await Directory(p.join(root.path, 'external')).create();
      final sentinel = File(p.join(external.path, 'keep'));
      await sentinel.writeAsString('preserve-external-data');
      final source = Link(
        p.join(documents.path, DownloadPersistentStorageV2.taskRecordsPath),
      );
      await source.create(external.path);
      await expectLater(storage.initialize(), throwsA(anything));
      expect(await source.exists(), isTrue);
      expect(await sentinel.readAsString(), 'preserve-external-data');
      expect(await storage.storedDatabaseVersion, ('Localstore', 0));
    },
  );

  test(
    'writes package JSON and sanitizes exactly the legacy filename characters',
    () async {
      const id = r'task\/:*?"<>|end';
      const safeId = 'task_________end';
      final download = task(id);
      final record = TaskRecord(download, TaskStatus.paused, 0.5, 1024);
      final resume = ResumeData(
        download,
        p.join(root.path, 'part'),
        512,
        'etag',
      );
      await Future.wait([
        storage.storeTaskRecord(record),
        storage.storePausedTask(download),
        storage.storeResumeData(resume),
      ]);
      for (final entry in {
        DownloadPersistentStorageV2.taskRecordsPath: record.toJson(),
        DownloadPersistentStorageV2.pausedTasksPath: download.toJson(),
        DownloadPersistentStorageV2.resumeDataPath: resume.toJson(),
      }.entries) {
        final file = File(p.join(support.path, entry.key, safeId));
        expect(jsonDecode(await file.readAsString()), entry.value);
      }
      await reopen();
      expect(await storage.retrieveTaskRecord(id), record);
      expect(await storage.retrievePausedTask(id), download);
      expect(await storage.retrieveResumeData(id), resume);
      await Future.wait([
        storage.removeTaskRecord(id),
        storage.removePausedTask(id),
        storage.removeResumeData(id),
      ]);
      await reopen();
      expect(await storage.retrieveTaskRecord(id), isNull);
      expect(await storage.retrievePausedTask(id), isNull);
      expect(await storage.retrieveResumeData(id), isNull);
      expect(await storage.retrieveAllTaskRecords(), isEmpty);
      expect(await storage.retrieveAllPausedTasks(), isEmpty);
      expect(await storage.retrieveAllResumeData(), isEmpty);
      for (final path in [
        DownloadPersistentStorageV2.taskRecordsPath,
        DownloadPersistentStorageV2.pausedTasksPath,
        DownloadPersistentStorageV2.resumeDataPath,
      ]) {
        expect(
          await File(p.join(support.path, path, safeId)).exists(),
          isFalse,
        );
      }
    },
  );

  test('shorter overwrites leave valid JSON after reopening', () async {
    final longRecord = TaskRecord(
      task('overwrite', metadata: 'x' * 8192),
      TaskStatus.running,
      0.5,
      4096,
    );
    final shortRecord = TaskRecord(
      task('overwrite'),
      TaskStatus.complete,
      1,
      4096,
    );
    await storage.storeTaskRecord(longRecord);
    await storage.storeTaskRecord(shortRecord);
    await reopen();
    expect(
      (await storage.retrieveTaskRecord('overwrite'))!.toJson(),
      shortRecord.toJson(),
    );
  });

  test('cold-start stores and deletes complete in submission order', () async {
    final operations = <Future<void>>[
      storage.initialize(),
      storage.initialize(),
    ];
    for (var index = 0; index < 32; index++) {
      final download = task('race-$index');
      operations.add(
        storage.storeTaskRecord(
          TaskRecord(download, TaskStatus.running, 0.5, 1024),
        ),
      );
      operations.add(storage.storePausedTask(download));
      operations.add(storage.storeResumeData(ResumeData(download, 'partial')));
      operations.add(storage.removeTaskRecord(download.taskId));
      operations.add(storage.removePausedTask(download.taskId));
      operations.add(storage.removeResumeData(download.taskId));
    }
    await Future.wait(operations);
    await reopen();
    expect(await storage.retrieveAllTaskRecords(), isEmpty);
    expect(await storage.retrieveAllPausedTasks(), isEmpty);
    expect(await storage.retrieveAllResumeData(), isEmpty);
  });

  test('collection deletion is ordered with later writes', () async {
    final oldTask = task('old');
    final newTask = task('new');
    await storage.storePausedTask(oldTask);
    await Future.wait([
      storage.storeTaskRecord(
        TaskRecord(oldTask, TaskStatus.paused, 0.5, 1024),
      ),
      storage.removeTaskRecord(null),
      storage.storeTaskRecord(
        TaskRecord(newTask, TaskStatus.complete, 1, 1024),
      ),
      storage.removePausedTask(null),
      storage.storePausedTask(newTask),
      storage.storeResumeData(ResumeData(oldTask, 'old-partial')),
      storage.removeResumeData(null),
      storage.storeResumeData(ResumeData(newTask, 'new-partial')),
    ]);
    await reopen();
    expect(
      (await storage.retrieveAllTaskRecords()).map((record) => record.taskId),
      ['new'],
    );
    expect(
      (await storage.retrieveAllPausedTasks()).map((task) => task.taskId),
      ['new'],
    );
    expect(
      (await storage.retrieveAllResumeData()).map((resume) => resume.taskId),
      ['new'],
    );
  });

  test(
    'write errors reach callers without poisoning later operations',
    () async {
      await storage.initialize();
      final blocked = File(
        p.join(support.path, DownloadPersistentStorageV2.taskRecordsPath),
      );
      if (await Directory(blocked.path).exists()) {
        await Directory(blocked.path).delete(recursive: true);
      }
      await blocked.writeAsString('blocked');
      final record = TaskRecord(task('recover'), TaskStatus.complete, 1, 1024);
      await expectLater(storage.storeTaskRecord(record), throwsA(anything));
      await blocked.delete();
      await storage.storeTaskRecord(record);
      await reopen();
      expect(await storage.retrieveTaskRecord(record.taskId), record);
    },
  );

  test('initialization retries after an IO failure is repaired', () async {
    final blocked = File(p.join(support.path, 'backgroundDownloaderDatabase'));
    await blocked.writeAsString('blocked');
    await expectLater(storage.initialize(), throwsA(anything));
    await blocked.delete();
    await storage.initialize();
    expect(await storage.storedDatabaseVersion, ('Localstore', 1));
    final record = TaskRecord(task('after-retry'), TaskStatus.complete, 1, 512);
    await storage.storeTaskRecord(record);
    expect(await storage.retrieveTaskRecord(record.taskId), record);
  });
}
