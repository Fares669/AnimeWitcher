import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/utils/download_resume.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bbflight.background_downloader');
  const bridge = MethodChannel(
    'com.animewitcher.app/download_continued_processing',
  );
  const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const connectivityStatus = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final storage = _Storage();
  final native = <String, Task>{};
  final enqueues = <List<dynamic>>[];
  Future<bool> Function(Task)? enqueueResult;
  late Directory root;
  late PathProviderPlatform previousPaths;
  late FileDownloader downloader;
  late PackageBackgroundDownloaderGateway gateway;
  var nextId = 0;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('gateway-source-fence-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
    messenger.setMockMethodCallHandler(connectivityStatus, (_) async => null);
    messenger.setMockMethodCallHandler(bridge, (call) async {
      if (call.method == 'availableDiskBytes') return 1000000000;
      if (call.method == 'retryMetadataForRange') return null;
      return true;
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'enqueue':
          final args = List<dynamic>.from(call.arguments as List);
          enqueues.add(args);
          final task = Task.createFromJson(
            jsonDecode(args.first as String) as Map<String, dynamic>,
          );
          final accepted =
              await (enqueueResult?.call(task) ?? Future.value(true));
          if (accepted) native[task.taskId] = task;
          return accepted;
        case 'allTasks':
          return [for (final task in native.values) jsonEncode(task.toJson())];
        case 'cancelTasksWithIds':
          for (final id in call.arguments as List) {
            native.remove(id);
          }
          return true;
        case 'pause':
          native.remove(call.arguments);
          return true;
        default:
          return null;
      }
    });
    downloader = FileDownloader(persistentStorage: storage);
    await downloader.ready;
    gateway = PackageBackgroundDownloaderGateway(
      downloader: downloader,
      retireDurableResumeCheckpoint: (id) async {
        await storage.removeResumeData(id);
        await storage.removePausedTask(id);
      },
      initializePackage: () async {},
      isIOS: () => true,
      notificationPreferences: () => DownloadNotificationPrefs.disabled,
    );
  });

  tearDownAll(() async {
    downloader.destroy();
    downloader.database.destroy();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(bridge, null);
    messenger.setMockMethodCallHandler(connectivity, null);
    messenger.setMockMethodCallHandler(connectivityStatus, null);
    debugDefaultTargetPlatformOverride = null;
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  Future<_Fixture> fixture({
    bool fenced = true,
    bool visible = true,
    PackageBackgroundDownloaderGateway? usingGateway,
  }) async {
    enqueues.clear();
    enqueueResult = null;
    final id = 'aw_v2_source_fence_${nextId++}_g1';
    final directory = await Directory('${root.path}/$id').create();
    final parent = ParallelDownloadTask(
      taskId: id,
      url: 'https://example.test/refreshed',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      group: kDownloadV2DurableParallelGroup,
      chunks: 2,
      allowPause: true,
    );
    final parts = await Directory('${await parent.filePath()}.parts').create();
    final children = [
      for (var index = 0; index < 2; index++)
        DownloadTask(
          taskId: '$id.part.$index',
          url: parent.url,
          filename: '$index.part',
          directory: parts.path,
          baseDirectory: BaseDirectory.root,
          group: kPersistentDownloadChunkGroup,
          allowPause: true,
          updates: Updates.statusAndProgress,
          headers: {
            'Range': 'bytes=${index * 4}-${index * 4 + 3}',
            'If-Range': '"same"',
          },
          metaData: jsonEncode({
            'parentTaskId': id,
            'attemptGeneration': 1,
            'sourceValidationRequired': index == 1 && fenced,
          }),
        ),
    ];
    final sibling = await File(await children.first.filePath())
        .writeAsBytes([1, 2, 3, 4]);
    final prefix = File(await children.last.filePath());
    if (visible) await prefix.writeAsBytes([5, 6]);
    await File('${parts.path}/manifest.json').writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'parentTaskId': id,
        'generation': 1,
        'checkpointSequence': 1,
        'expectedBytes': 8,
        'totalBytes': 8,
        'resourceValidator': '"same"',
        'resourceValidatorQualified': true,
        'parts': [
          for (var index = 0; index < 2; index++)
            {
              'task': children[index].toJson(),
              'from': index * 4,
              'to': index * 4 + 3,
              'progress': index == 0 ? 1.0 : .5,
              'credibleProgress': index == 0 ? 1.0 : .5,
              'durableBytes': index == 0 ? 4 : (visible ? 2 : 0),
              'complete': index == 0,
              'attemptGeneration': 1,
              'sourceValidationRequired': index == 1 && fenced,
            },
        ],
      }),
    );
    await storage.storeResumeData(
      ResumeData(
        children.last.copyWith(url: 'https://example.test/expired'),
        'opaque-old-source',
        2,
      ),
    );
    await storage.storePausedTask(children.last);
    await downloader.database.updateRecord(
      TaskRecord(parent, TaskStatus.paused, .75, 8),
    );
    final handle = (await (usingGateway ?? gateway).attach(id))!;
    final f = _Fixture(
      handle,
      children.last,
      prefix,
      sibling,
      await privateParallelManifestFileV2(parent),
    );
    addTearDown(() async {
      enqueueResult = null;
      await handle.cancel().timeout(const Duration(seconds: 3));
    });
    return f;
  }

  test(
    'injected downloader without its storage callback fails closed',
    () async {
      final unpaired = PackageBackgroundDownloaderGateway(
        downloader: _UnpairedDownloader(downloader),
        initializePackage: () async {},
        isIOS: () => true,
      );
      final f = await fixture(usingGateway: unpaired);
      await f.handle.resume().timeout(const Duration(seconds: 3));
      expect(enqueues, isEmpty);
      expect(
        (await storage.retrieveResumeData(f.child.taskId))?.data,
        'opaque-old-source',
      );
      expect(await storage.retrievePausedTask(f.child.taskId), isNotNull);
      expect((await f.parts()).last['sourceValidationRequired'], isTrue);
      expect(await f.prefix.readAsBytes(), [5, 6]);
      expect(await f.sibling.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test('source fence uses a fresh native request and retains visible bytes when enqueue fails', () async {
    final f = await fixture();
    enqueueResult = (_) async => false;
    await f.handle.resume().timeout(const Duration(seconds: 3));
    expect(enqueues, hasLength(1));
    expect(
      enqueues.single,
      hasLength(2),
      reason: '5 native arguments consume opaque resumeData from the old URL',
    );
    expect(await f.prefix.readAsBytes(), [5, 6]);
    expect(await f.sibling.readAsBytes(), [1, 2, 3, 4]);
    final part = (await f.parts()).last;
    expect(part['sourceValidationRequired'], isTrue);
    expect(part['durableBytes'], 2);
    expect(native.containsKey(f.child.taskId), isFalse);
  });

  test('successful fresh replacement durably clears the fence without serial queue deadlock', () async {
    final f = await fixture();
    expect(await f.handle.resume().timeout(const Duration(seconds: 3)), isTrue);
    expect(enqueues.single, hasLength(2));
    expect((await f.parts()).last['sourceValidationRequired'], isFalse);
    expect(
      await storage.retrieveResumeData(f.child.taskId),
      isNull,
      reason: 'a later resume must not reuse the old source blob',
    );
    expect(await storage.retrievePausedTask(f.child.taskId), isNull);
    await f.handle.resume().timeout(const Duration(seconds: 3));
    expect(
      enqueues,
      hasLength(1),
      reason: 'the accepted native writer stays owned',
    );
    expect(await f.sibling.readAsBytes(), [1, 2, 3, 4]);
  });

  test('later resume uses only the replacement source checkpoint', () async {
    final f = await fixture();
    await f.handle.resume().timeout(const Duration(seconds: 3));
    expect(await storage.retrieveResumeData(f.child.taskId), isNull);
    final task = native.remove(f.child.taskId)!;
    await storage.storeResumeData(
      ResumeData(task, 'opaque-refreshed-source', 2),
    );
    await storage.storePausedTask(task);
    await f.handle.pause().timeout(const Duration(seconds: 3));
    await f.handle.resume().timeout(const Duration(seconds: 3));
    expect(enqueues, hasLength(2));
    expect(enqueues.first, hasLength(2));
    expect(enqueues.last, hasLength(5));
    expect(enqueues.last[2], 'opaque-refreshed-source');
    expect(await f.sibling.readAsBytes(), [1, 2, 3, 4]);
  });

  test(
    'unknown fresh enqueue ACK keeps the fence and prevents a second writer',
    () async {
      final f = await fixture();
      final ack = Completer<bool>();
      enqueueResult = (task) {
        native[task.taskId] = task;
        return ack.future;
      };
      try {
        await f.handle.resume().timeout(const Duration(seconds: 7));
        expect((await f.parts()).last['sourceValidationRequired'], isTrue);
        await f.handle.resume().timeout(const Duration(seconds: 3));
        expect(enqueues, hasLength(1));
        expect(enqueues.single, hasLength(2));
        expect(await f.prefix.readAsBytes(), [5, 6]);
      } finally {
        ack.complete(true);
        await Future<void>.delayed(Duration.zero);
      }
    },
  );

  test(
    'ordinary unfenced resume still sends the package opaque resume checkpoint',
    () async {
      final f = await fixture(fenced: false);
      expect(
        await f.handle.resume().timeout(const Duration(seconds: 3)),
        isTrue,
      );
      expect(enqueues.single, hasLength(5));
      expect(enqueues.single[2], 'opaque-old-source');
      expect(await f.prefix.readAsBytes(), [5, 6]);
    },
  );

  test('opaque-only fenced range refetches only that range', () async {
    final f = await fixture(visible: false);
    expect(await f.handle.resume().timeout(const Duration(seconds: 3)), isTrue);
    expect(enqueues, hasLength(1));
    expect(enqueues.single, hasLength(2));
    final task = Task.createFromJson(
      jsonDecode(enqueues.single.first as String) as Map<String, dynamic>,
    );
    expect(task.taskId, f.child.taskId);
    expect(task.headers['Range'], 'bytes=4-7');
    expect(await f.sibling.readAsBytes(), [1, 2, 3, 4]);
  });

  test('failed native final move leaves a recoverable prefix after deleting its destination', () async {
    final f = await fixture();
    await f.handle.resume().timeout(const Duration(seconds: 3));
    // Pinned iOS 9.6.4 removes the destination before moving URLSession's body.
    await f.prefix.delete();
    native.remove(f.child.taskId);
    final recovered = await canonicalizePartialDownloadFile(
      destinationPath: f.prefix.path,
    );
    expect(recovered?.bytes, 2);
    expect(await f.prefix.readAsBytes(), [5, 6]);
    expect(await f.sibling.readAsBytes(), [1, 2, 3, 4]);
  });

  test('malformed replacement completion retains the saved prefix', () async {
    final f = await fixture();
    await f.handle.resume().timeout(const Duration(seconds: 3));
    final task = native.remove(f.child.taskId)!;
    await f.prefix.writeAsBytes([9, 9, 9, 9]);
    final paused = f.handle.snapshots.firstWhere(
      (snapshot) => snapshot.status == DownloadTransportStatus.paused,
    );
    // Exercise the production package update stream and gateway coordinator.
    // ignore: invalid_use_of_visible_for_testing_member
    downloader.downloaderForTesting.processStatusUpdate(
      TaskStatusUpdate(task, TaskStatus.complete, null, null, {
        'content-range': 'bytes 0-3/8',
        'etag': '"same"',
      }, 206),
    );
    await paused.timeout(const Duration(seconds: 3));
    final recovered = await canonicalizePartialDownloadFile(
      destinationPath: f.prefix.path,
    );
    expect(recovered?.bytes, 2);
    expect(await f.prefix.readAsBytes(), [5, 6]);
    expect(await f.sibling.readAsBytes(), [1, 2, 3, 4]);
  });
}

final class _Fixture {
  _Fixture(this.handle, this.child, this.prefix, this.sibling, this.manifest);
  final DownloadTransportHandle handle;
  final DownloadTask child;
  final File prefix;
  final File sibling;
  final File manifest;
  Future<List<dynamic>> parts() async =>
      (jsonDecode(await manifest.readAsString()) as Map)['parts'] as List;
}

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
}

final class _Storage implements PersistentStorage {
  final records = <String, TaskRecord>{};
  final paused = <String, Task>{};
  final resume = <String, ResumeData>{};
  @override
  Future<void> initialize() async {}
  @override
  (String, int) get currentDatabaseVersion => ('test', 1);
  @override
  Future<(String, int)> get storedDatabaseVersion async =>
      currentDatabaseVersion;
  @override
  Future<void> storeTaskRecord(TaskRecord value) async {
    records[value.taskId] = value;
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String id) async => records[id];
  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async =>
      records.values.toList();
  @override
  Future<void> removeTaskRecord(String? id) async {
    id == null ? records.clear() : records.remove(id);
  }

  @override
  Future<void> storePausedTask(Task value) async {
    paused[value.taskId] = value;
  }

  @override
  Future<Task?> retrievePausedTask(String id) async => paused[id];
  @override
  Future<List<Task>> retrieveAllPausedTasks() async => paused.values.toList();
  @override
  Future<void> removePausedTask(String? id) async {
    id == null ? paused.clear() : paused.remove(id);
  }

  @override
  Future<void> storeResumeData(ResumeData value) async {
    resume[value.taskId] = value;
  }

  @override
  Future<ResumeData?> retrieveResumeData(String id) async => resume[id];
  @override
  Future<List<ResumeData>> retrieveAllResumeData() async =>
      resume.values.toList();
  @override
  Future<void> removeResumeData(String? id) async {
    id == null ? resume.clear() : resume.remove(id);
  }
}

/// Keep the actual package engine and store, but provide an independent empty
/// observation stream for a gateway that must never admit this fenced task.
final class _UnpairedDownloader implements FileDownloader {
  _UnpairedDownloader(this.delegate);
  final FileDownloader delegate;
  @override
  Database get database => delegate.database;
  @override
  Transfers get transfers => delegate.transfers;
  @override
  Stream<TaskUpdate> get updates => const Stream.empty();
  @override
  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) => delegate.allTasks(
    group: group,
    includeTasksWaitingToRetry: includeTasksWaitingToRetry,
    allGroups: allGroups,
  );
  @override
  Future<bool> taskCanResume(Task task) => delegate.taskCanResume(task);
  @override
  Future<bool> resume(DownloadTask task) => delegate.resume(task);
  @override
  Future<bool> enqueue(Task task) => delegate.enqueue(task);
  @override
  Future<bool> cancelTasksWithIds(Iterable<String> ids) =>
      delegate.cancelTasksWithIds(ids);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
