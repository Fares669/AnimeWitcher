import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'gateway subscribes before package replays background updates',
    () async {
      final downloader = _StartupDownloader();
      addTearDown(downloader.database.destroy);
      final gateway = PackageBackgroundDownloaderGateway(
        downloader: downloader,
        notificationPreferences: () => DownloadNotificationPrefs.disabled,
      );

      await gateway.initialize();

      expect(downloader.listenerPresentAtReplay, isTrue);
      await downloader.updatesController.close();
    },
  );

  test(
    'startup preserves old completion records until V2 reconciles them',
    () async {
      final downloader = _StartupDownloader();
      addTearDown(downloader.database.destroy);
      final completed = TaskRecord(
        DownloadTask(
          taskId: 'old-background-completion',
          url: 'https://example.invalid/video',
          filename: 'video.mp4',
          creationTime: DateTime.now().subtract(const Duration(days: 11)),
        ),
        TaskStatus.complete,
        1,
        100,
      );
      await downloader.database.updateRecord(completed);
      final gateway = PackageBackgroundDownloaderGateway(
        downloader: downloader,
        notificationPreferences: () => DownloadNotificationPrefs.disabled,
      );

      await gateway.initialize();
      await Future<void>.delayed(Duration.zero);

      expect(
        await downloader.database.recordForId(completed.taskId),
        isNotNull,
      );
      await downloader.updatesController.close();
    },
  );

  test(
    'gateway parks assembly on the destination volume without deleting ranges',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aw_gateway_storage_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final downloader = _StartupDownloader();
      addTearDown(downloader.database.destroy);
      final parent = ParallelDownloadTask(
        taskId: 'storage-parent',
        url: 'https://example.invalid/video',
        filename: 'video.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        group: kDownloadV2DurableParallelGroup,
        chunks: 2,
        allowPause: true,
      );
      final parts = Directory('${directory.path}/video.mp4.parts');
      await parts.create();
      final children = <DownloadTask>[
        for (var index = 0; index < 2; index++)
          DownloadTask(
            taskId: '${parent.taskId}.part.$index',
            url: parent.url,
            filename: '$index.part',
            directory: parts.path,
            baseDirectory: BaseDirectory.root,
            group: 'animewitcher_parts',
            headers: <String, String>{
              'Range': 'bytes=${index * 4}-${index * 4 + 3}',
            },
            metaData: jsonEncode(<String, String>{
              'parentTaskId': parent.taskId,
            }),
          ),
      ];
      for (final child in children) {
        await File(await child.filePath()).writeAsBytes(<int>[1, 2, 3, 4]);
      }
      await File('${parts.path}/manifest.json').writeAsString(
        jsonEncode(<String, Object>{
          'schemaVersion': 2,
          'parentTaskId': parent.taskId,
          'generation': 1,
          'checkpointSequence': 1,
          'expectedBytes': 8,
          'totalBytes': 8,
          'parts': <Object>[
            for (var index = 0; index < 2; index++)
              <String, Object>{
                'task': children[index].toJson(),
                'from': index * 4,
                'to': index * 4 + 3,
                'progress': 1.0,
                'credibleProgress': 1.0,
                'durableBytes': 4,
                'complete': true,
                'attemptGeneration': 1,
              },
          ],
        }),
      );
      await downloader.database.updateRecord(
        TaskRecord(parent, TaskStatus.paused, 1, 8),
      );
      const channel = MethodChannel(
        'com.animewitcher.app/download_continued_processing',
      );
      MethodCall? storageProbe;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            storageProbe = call;
            return 0;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final gateway = PackageBackgroundDownloaderGateway(
        downloader: downloader,
        initializePackage: () async {},
        isIOS: () => true,
      );
      final handle = (await gateway.attach(parent.taskId))!;
      addTearDown(() async {
        await handle.cancel();
        await downloader.updatesController.close();
      });

      await handle.resume();

      expect(storageProbe!.arguments, <String, Object>{'path': directory.path});
      expect(handle.current.status, DownloadTransportStatus.paused);
      expect(await File('${directory.path}/video.mp4').exists(), isFalse);
      for (final child in children) {
        expect(await File(await child.filePath()).readAsBytes(), <int>[
          1,
          2,
          3,
          4,
        ]);
      }
    },
  );

  test(
    'storage probe reads free bytes for the actual destination volume',
    () async {
      const channel = MethodChannel(
        'com.animewitcher.app/download_continued_processing',
      );
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            received = call;
            return 4096;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      expect(await availableDownloadStorageBytesV2('/downloads/episode'), 4096);
      expect(received!.method, 'availableDiskBytes');
      expect(received!.arguments, <String, Object>{
        'path': '/downloads/episode',
      });
    },
  );

  test(
    'storage probe allows unsupported native hosts to retain fallback',
    () async {
      expect(await availableDownloadStorageBytesV2('/downloads'), isNull);
    },
  );
}

final class _StartupDownloader implements FileDownloader {
  _StartupDownloader() : database = Database(_StartupStorage());

  @override
  final Database database;
  final updatesController = StreamController<TaskUpdate>.broadcast();
  bool listenerPresentAtReplay = false;

  @override
  Stream<TaskUpdate> get updates => updatesController.stream;

  @override
  Future<List<(String, String)>> configure({
    dynamic globalConfig,
    dynamic androidConfig,
    dynamic iOSConfig,
    dynamic desktopConfig,
  }) async => <(String, String)>[];

  @override
  Future<void> start({
    bool doTrackTasks = true,
    bool markDownloadedComplete = true,
    bool doRescheduleKilledTasks = true,
    bool autoCleanDatabase = false,
  }) async {
    listenerPresentAtReplay = updatesController.hasListener;
    if (autoCleanDatabase) database.cleanUp();
  }

  @override
  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) async => <Task>[];

  @override
  Future<bool> cancelTasksWithIds(Iterable<String> taskIds) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StartupStorage implements PersistentStorage {
  final records = <String, TaskRecord>{};

  @override
  Future<void> storeTaskRecord(TaskRecord record) async {
    records[record.taskId] = record;
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String taskId) async =>
      records[taskId];

  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async =>
      records.values.toList();

  @override
  Future<void> removeTaskRecord(String? taskId) async {
    if (taskId == null) {
      records.clear();
    } else {
      records.remove(taskId);
    }
  }

  @override
  Future<List<Task>> retrieveAllPausedTasks() async => <Task>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
