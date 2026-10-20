import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

// Real manager, production package gateway/coordinator, on-disk checkpoints,
// task update stream and loopback HTTP byte verification. Package/native transport
// is simulated; these are not physical iOS URLSession integration tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  const bridge = MethodChannel(
    'com.animewitcher.app/download_continued_processing',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final storage = _Storage();
  final native = <String, Task>{};
  final enqueued = <Task>[];
  late Directory root;
  late PathProviderPlatform previousPaths;
  late _Downloader downloader;
  late PackageBackgroundDownloaderGateway gateway;
  late HttpServer server;
  late String origin;
  var nextId = 0;
  var changedSource = false;
  var renewedTotalBytes = 8;
  Completer<HttpRequest>? blockedProbe;
  Completer<void>? releaseProbe;
  final probes = <String>[];
  final diagnostics = InMemoryDownloadDiagnosticsV2();

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('manager-range-renewal-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(bridge, (call) async {
      if (call.method == 'availableDiskBytes') return 1000000000;
      if (call.method == 'retryMetadataForRange') return null;
      return true;
    });
    downloader = _Downloader(storage, native, enqueued);
    gateway = PackageBackgroundDownloaderGateway(
      downloader: downloader,
      diagnostics: diagnostics,
      retireDurableResumeCheckpoint: (id) async {
        await storage.removeResumeData(id);
        await storage.removePausedTask(id);
      },
      initializePackage: () async {},
      isIOS: () => true,
      rangeCapabilityProbe: (_) async =>
          (supportsRanges: true, totalBytes: renewedTotalBytes),
      notificationPreferences: () => DownloadNotificationPrefs.disabled,
    );

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://${server.address.address}:${server.port}';
    server.listen((request) async {
      final match = RegExp(r'bytes=(\d+)-(\d+)')
          .firstMatch(request.headers.value('range') ?? '');
      if (match == null) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final from = int.parse(match[1]!);
      final to = int.parse(match[2]!);
      probes.add('${request.uri.path}:$from-$to');
      if (blockedProbe case final blocked? when request.uri.path == '/fresh') {
        if (!blocked.isCompleted) blocked.complete(request);
        await releaseProbe!.future;
      }
      final bytes = changedSource && request.uri.path == '/fresh'
          ? [8, 7, 6, 5, 4, 3, 2, 1]
          : [1, 2, 3, 4, 5, 6, 7, 8];
      request.response.statusCode = 206;
      request.response.headers.set('Content-Range', 'bytes $from-$to/8');
      request.response.headers.set('ETag', '"same-resource"');
      request.response.add(bytes.sublist(from, to + 1));
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    await downloader.updatesController.close();
    downloader.database.destroy();
    await Future<void>.delayed(Duration.zero);
    for (final c in [bridge]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    debugDefaultTargetPlatformOverride = null;
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  setUp(() {
    enqueued.clear();
    probes.clear();
    changedSource = false;
    renewedTotalBytes = 8;
    blockedProbe = null;
    releaseProbe = null;
  });

  Future<
    ({
      DownloadManagerV2 manager,
      InMemoryLogicalDownloadStoreV2 store,
      DownloadLogicalId id,
      ParallelDownloadTask parent,
      File completePart,
      File partialPart,
      _Resolver resolver,
    })
  >
  fixture() async {
    final id = logicalDownloadIdFor(
      animeId: 'range-audit',
      episodeKey: '${nextId++}',
      variantKey: '1080p',
    );
    final directory = await Directory('${root.path}/${id.value}').create();
    final parent = ParallelDownloadTask(
      taskId: taskIdForGeneration(id, 1),
      url: '$origin/old',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      group: kDownloadV2DurableParallelGroup,
      chunks: 2,
      allowPause: true,
    );
    final parts = await Directory('${await parent.filePath()}.parts').create();
    final children = [
      for (var i = 0; i < 2; i++)
        DownloadTask(
          taskId: '${parent.taskId}.part.$i',
          url: parent.url,
          filename: '$i.part',
          directory: parts.path,
          baseDirectory: BaseDirectory.root,
          group: kPersistentDownloadChunkGroup,
          allowPause: true,
          updates: Updates.statusAndProgress,
          headers: {
            'Range': 'bytes=${i * 4}-${i * 4 + 3}',
            'If-Range': '"same-resource"',
          },
          metaData: jsonEncode({
            'parentTaskId': parent.taskId,
            'attemptGeneration': 1,
          }),
        ),
    ];
    final completePart = await File(await children.first.filePath())
        .writeAsBytes([1, 2, 3, 4]);
    final partialPart = await File(await children.last.filePath())
        .writeAsBytes([5, 6]);
    await File('${parts.path}/manifest.json').writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'parentTaskId': parent.taskId,
        'generation': 1,
        'checkpointSequence': 1,
        'expectedBytes': 8,
        'totalBytes': 8,
        'resourceValidator': '"same-resource"',
        'resourceValidatorQualified': true,
        'parts': [
          for (var i = 0; i < 2; i++)
            {
              'task': children[i].toJson(),
              'from': i * 4,
              'to': i * 4 + 3,
              'progress': i == 0 ? 1.0 : .5,
              'credibleProgress': i == 0 ? 1.0 : .5,
              'durableBytes': i == 0 ? 4 : 2,
              'complete': i == 0,
              'attemptGeneration': 1,
            },
        ],
      }),
    );
    await downloader.database.updateRecord(
      TaskRecord(parent, TaskStatus.paused, .75, 8),
    );
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(
      LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: id,
        mediaId: 'range-audit',
        unitKey: '${nextId - 1}',
        variantKey: '1080p',
        generation: 1,
        taskId: parent.taskId,
        intent: DownloadUserIntent.active,
        destinationPath: await parent.filePath(),
        sourceDescriptor: const {'provider': 'audit'},
        expectedBytes: 8,
        parallelChunks: 2,
        updatedAtMillis: 1,
      ),
    );
    final resolver = _Resolver(
      () => ResolvedDownloadSourceV2(
        url: '$origin/fresh',
        expectedBytes: renewedTotalBytes,
      ),
    );
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    addTearDown(() async {
      await manager.cancel(id);
      await manager.dispose();
    });
    await manager.initialize();
    await until(
      () => native.values.any((task) => task.taskId == children.last.taskId),
      'initial native start; snapshot=${manager.snapshotFor(id)?.status}; enqueues=${enqueued.map((t) => t.taskId).toList()}',
    );
    expect(
      enqueued.where((task) => task.taskId == children.first.taskId),
      isEmpty,
    );
    return (
      manager: manager,
      store: store,
      id: id,
      parent: parent,
      completePart: completePart,
      partialPart: partialPart,
      resolver: resolver,
    );
  }

  void expire(ParallelDownloadTask parent) {
    final child = native.remove('${parent.taskId}.part.1');
    if (child == null)
      throw StateError(
        'Missing native: ${diagnostics.transportEvents.reversed.take(30).toList()}',
      );
    downloader.updatesController.add(
      TaskStatusUpdate(
        child,
        TaskStatus.failed,
        TaskHttpException('expired', 403),
        null,
        null,
        403,
      ),
    );
  }

  test('expired URL renewal retains real durable parts and the exact generation', () async {
    final f = await fixture();
    expire(f.parent);
    await until(() => f.resolver.calls > 0, 'source resolver invoked');
    await until(
      () => enqueued.any((task) => task.url.endsWith('/fresh')),
      'renewed native enqueue',
    );
    expect(
      await f.completePart.exists(),
      isTrue,
      reason: 'the already downloaded complete range must survive URL renewal',
    );
    expect(
      (await f.store.get(f.id))?.generation,
      1,
      reason:
          'renewing credentials is not permission to discard downloaded ranges',
    );
    expect(await f.completePart.readAsBytes(), [1, 2, 3, 4]);
    expect(await f.partialPart.readAsBytes(), [5, 6]);
    final freshTasks = enqueued
        .where((task) => task.url.endsWith('/fresh'))
        .toList();
    expect(freshTasks, hasLength(1));
    expect(freshTasks.single.taskId, '${f.parent.taskId}.part.1');
    expect(freshTasks.single.headers['Range'], 'bytes=4-7');
    expect(probes, contains('/fresh:0-3'));
    expect(probes, contains('/fresh:4-5'));
  });

  test('same-size changed renewed source fails closed without destroying saved bytes', () async {
    final f = await fixture();
    changedSource = true;
    expire(f.parent);
    await until(() => f.resolver.calls > 0, 'source resolver invoked');
    await until(
      () async =>
          (await f.store.get(f.id))?.intent == DownloadUserIntent.failed,
      'durable source failure',
    );
    expect((await f.store.get(f.id))?.generation, 1);
    expect((await f.store.get(f.id))?.intent, DownloadUserIntent.failed);
    expect(await f.completePart.readAsBytes(), [1, 2, 3, 4]);
    expect(await f.partialPart.readAsBytes(), [5, 6]);
    expect(enqueued.where((task) => task.url.endsWith('/fresh')), isEmpty);
  });

  test(
    'renewal rejects a changed resource size without clearing checkpoints',
    () async {
      final f = await fixture();
      renewedTotalBytes = 9;
      expire(f.parent);
      await until(
        () async =>
            (await f.store.get(f.id))?.intent == DownloadUserIntent.failed,
      );
      expect((await f.store.get(f.id))?.generation, 1);
      expect(await f.completePart.readAsBytes(), [1, 2, 3, 4]);
      expect(await f.partialPart.readAsBytes(), [5, 6]);
      expect(enqueued.where((task) => task.url.endsWith('/fresh')), isEmpty);
      expect(probes.where((probe) => probe.startsWith('/fresh')), isEmpty);
    },
  );

  for (final control in ['pause', 'cancel', 'delete']) {
    test(
      '$control interrupts a blocked real renewal byte probe before any new writer starts',
      () async {
        final f = await fixture();
        blockedProbe = Completer<HttpRequest>();
        releaseProbe = Completer<void>();
        try {
          expire(f.parent);
          await blockedProbe!.future.timeout(const Duration(seconds: 3));
          final Future<Object?> stopped = switch (control) {
            'pause' => f.manager.pause(f.id),
            'cancel' => f.manager.cancel(f.id),
            _ => f.manager.delete(f.id),
          };
          await stopped.timeout(const Duration(seconds: 2));
          expect(
            enqueued.where((task) => task.url.endsWith('/fresh')),
            isEmpty,
          );
          expect(native, isEmpty);
          final record = await f.store.get(f.id);
          if (control == 'pause') {
            expect(record?.intent, DownloadUserIntent.paused);
            expect(record?.generation, 1);
            expect(await f.completePart.readAsBytes(), [1, 2, 3, 4]);
            expect(await f.partialPart.readAsBytes(), [5, 6]);
          } else if (control == 'cancel') {
            expect(record?.intent, DownloadUserIntent.canceled);
          } else {
            expect(record, isNull);
          }
        } finally {
          if (!releaseProbe!.isCompleted) releaseProbe!.complete();
          blockedProbe = null;
        }
      },
    );
  }
}

Future<void> until(
  FutureOr<bool> Function() predicate, [
  String reason = 'condition',
]) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline))
      throw TimeoutException('$reason was not reached');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _Resolver implements DownloadSourceResolverV2 {
  _Resolver(this.source);
  final ResolvedDownloadSourceV2 Function() source;
  int calls = 0;
  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    calls++;
    return source();
  }
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

final class _Downloader implements FileDownloader {
  _Downloader(this.storage, this.native, this.enqueued)
    : database = Database(storage) {
    transfers = _Transfers(this);
  }
  final _Storage storage;
  final Map<String, Task> native;
  final List<Task> enqueued;
  final updatesController = StreamController<TaskUpdate>.broadcast();
  @override
  final Database database;
  @override
  late final Transfers transfers;
  @override
  Stream<TaskUpdate> get updates => updatesController.stream;
  @override
  Future<bool> enqueue(Task task) async {
    enqueued.add(task);
    native[task.taskId] = task;
    return true;
  }

  @override
  Future<bool> taskCanResume(Task task) async =>
      storage.resume.containsKey(task.taskId);
  @override
  Future<bool> resume(DownloadTask task) => enqueue(task);
  @override
  Future<bool> pause(DownloadTask task) async {
    native.remove(task.taskId);
    await storage.storePausedTask(task);
    await storage.storeResumeData(ResumeData(task, 'opaque-native-checkpoint'));
    return true;
  }

  @override
  Future<bool> cancelTasksWithIds(Iterable<String> ids) async {
    for (final id in ids) {
      native.remove(id);
    }
    return true;
  }

  @override
  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) async => [
    for (final task in [...storage.paused.values, ...native.values])
      if (allGroups || task.group == group) task,
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transfers implements Transfers {
  _Transfers(this.downloader);
  @override
  final FileDownloader downloader;
  @override
  Future<List<Transfer>> rehydrateFromDatabase({String? group}) async => [];
  @override
  Transfer? forId(String taskId) => null;
  @override
  Transfer? remove(String taskId, {bool dispose = true}) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
