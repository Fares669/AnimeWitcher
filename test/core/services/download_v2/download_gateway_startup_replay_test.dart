import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  late PathProviderPlatform oldPaths;
  setUp(() async {
    oldPaths = PathProviderPlatform.instance;
    fixture = await _Fixture.create();
  });
  tearDown(() async {
    await fixture.dispose();
    PathProviderPlatform.instance = oldPaths;
  });

  for (final timing in ['configure', 'start', 'restore', 'after']) {
    test('preserves validated completion arriving at $timing', () async {
      Future<void> emit() => fixture.downloader.emit(fixture.complete());
      switch (timing) {
        case 'configure':
          fixture.downloader.onConfigure = emit;
        case 'start':
          fixture.downloader.onStart = emit;
        case 'restore':
          fixture.paths.onSupport = emit;
      }
      await fixture.gateway.initialize();
      if (timing == 'after') {
        await fixture.gateway.attach(fixture.parent.taskId);
        await emit();
        await fixture.untilCompleted();
      }
      final handle = (await fixture.gateway.attach(fixture.parent.taskId))!;
      expect((await fixture.partState())['complete'], isTrue);
      if (timing != 'after') expect(handle.current.transferredBytes, 4);
      expect(fixture.verificationEvents, isEmpty);
    });
  }

  test(
    'duplicate completions keep exact bytes and validate only once',
    () async {
      fixture.downloader.onStart = () async {
        for (var index = 0; index < 5; index++) {
          await fixture.downloader.emit(fixture.complete());
        }
      };
      await fixture.gateway.initialize();
      final handle = (await fixture.gateway.attach(fixture.parent.taskId))!;
      expect(handle.current.transferredBytes, 4);
      expect((await fixture.partState())['complete'], isTrue);
      expect(fixture.verificationEvents, isEmpty);
      expect(await fixture.file.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test(
    'stale attempts and unknown parent generations cannot credit bytes',
    () async {
      fixture.downloader.onStart = () async {
        await fixture.downloader.emit(fixture.complete(attempt: 2));
        await fixture.downloader.emit(
          fixture.complete(
            child: fixture.child.copyWith(taskId: 'old-parent-g0.part.0'),
          ),
        );
      };
      await fixture.gateway.initialize();
      final handle = (await fixture.gateway.attach(fixture.parent.taskId))!;
      expect(handle.current.transferredBytes, 0);
      expect((await fixture.partState())['complete'], isFalse);
      expect(
        fixture.diagnostics.transportEvents.where(
          (event) => event['event'] == 'parallel.staleChildCallback',
        ),
        hasLength(1),
      );
      expect(await fixture.file.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test(
    'database complete and headerless synthetic complete are not HTTP proof',
    () async {
      await fixture.downloader.database.updateRecord(
        TaskRecord(fixture.child, TaskStatus.complete, 1, 4),
      );
      fixture.downloader.onStart = () => fixture.downloader.emit(
        TaskStatusUpdate(fixture.child, TaskStatus.complete),
      );
      await fixture.gateway.initialize();
      final handle = (await fixture.gateway.attach(fixture.parent.taskId))!;
      expect(handle.current.transferredBytes, 0);
      expect((await fixture.partState())['complete'], isFalse);
      expect(
        fixture.verificationEvents,
        isEmpty,
        reason: 'Inactive startup replay must not await network verification',
      );
      expect(await fixture.file.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test(
    'manifest-only parent is restored before captured completion replay',
    () async {
      await fixture.downloader.database.deleteRecordWithId(
        fixture.parent.taskId,
      );
      fixture.downloader.onStart = () =>
          fixture.downloader.emit(fixture.complete());
      await fixture.gateway.initialize();
      final handle = (await fixture.gateway.attach(fixture.parent.taskId))!;
      expect(handle.current.transferredBytes, 4);
      expect((await fixture.partState())['complete'], isTrue);
      expect(fixture.verificationEvents, isEmpty);
    },
  );

  test(
    'callback flush does not wait for callbacks queued after its snapshot',
    () async {
      final laterEntered = Completer<void>();
      final releaseLater = Completer<void>();
      final manifest = jsonDecode(await fixture.manifest.readAsString()) as Map;
      final second = Task.createFromJson(
        Map<String, dynamic>.from(
          ((manifest['parts'] as List)[1] as Map)['task'] as Map,
        ),
      ) as DownloadTask;
      await File(await second.filePath()).writeAsBytes([5, 6, 7, 8]);
      final coordinator = PersistentParallelDownload(
        startPart: (_, _, _) async => false,
        pausePart: (_) async {},
        cancelParts: (_) async {},
        recordForId: fixture.downloader.database.recordForId,
        saveRecord: (record) async {
          if (record.taskId == second.taskId) {
            laterEntered.complete();
            await releaseLater.future;
          }
          await fixture.downloader.database.updateRecord(record);
        },
        onUpdate: (_) {},
        onPartProgress: (_, _, _) {},
        manifestFileResolver: (_) async => fixture.manifest,
      );
      try {
        expect(await coordinator.restore(fixture.parent), isTrue);
        coordinator.handleUpdate(fixture.complete());
        final captured = coordinator.flushPendingUpdates();
        coordinator.handleUpdate(
          TaskStatusUpdate(second, TaskStatus.complete, null, null, {
            'content-range': 'bytes 4-7/8',
            'etag': '"resource"',
          }, 206),
        );
        await captured.timeout(const Duration(seconds: 1));
        await laterEntered.future.timeout(const Duration(seconds: 1));
        expect(releaseLater.isCompleted, isFalse);
      } finally {
        releaseLater.complete();
        await coordinator.dispose();
      }
    },
  );

  test('replay preserves response range checks', () async {
    fixture.downloader.onStart = () => fixture.downloader.emit(
      TaskStatusUpdate(fixture.child, TaskStatus.complete, null, null, {
        'content-range': 'bytes 4-7/8',
      }, 206),
    );
    await fixture.gateway.initialize();
    expect((await fixture.partState())['complete'], isFalse);
    expect(
      fixture.diagnostics.transportEvents.where(
        (event) => event['event'] == 'parallel.rangeRejected',
      ),
      hasLength(1),
    );
  });

  test('failure before completion still fences the old attempt', () async {
    fixture.downloader.native.add(fixture.child);
    fixture.downloader.onStart = () async {
      await fixture.downloader.emit(
        TaskStatusUpdate(
          fixture.child,
          TaskStatus.failed,
          TaskConnectionException('test'),
        ),
      );
      await fixture.downloader.emit(fixture.complete());
    };
    await fixture.gateway.initialize();
    expect((await fixture.partState())['complete'], isFalse);
    expect((await fixture.partState())['attemptGeneration'], 2);
    expect(await fixture.file.readAsBytes(), [1, 2, 3, 4]);
  });

  test(
    'slow full-body native settlement cannot hold local initialization',
    () async {
      final release = Completer<bool>();
      final entered = Completer<void>();
      fixture.downloader.onCancel = () {
        if (!entered.isCompleted) entered.complete();
        return release.future;
      };
      await fixture.file.writeAsBytes(List.filled(8, 1));
      fixture.downloader.onStart = () => fixture.downloader.emit(
        TaskStatusUpdate(fixture.child, TaskStatus.complete, null, null, {
          'content-length': '8',
        }, 200),
      );
      try {
        await fixture.gateway.initialize().timeout(const Duration(seconds: 2));
        expect(entered.isCompleted, isTrue);
        expect(release.isCompleted, isFalse);
        expect(await fixture.gateway.attach(fixture.parent.taskId), isNotNull);
        expect(fixture.verificationEvents, isEmpty);
      } finally {
        release.complete(true);
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (!fixture.diagnostics.transportEvents.any(
          (event) =>
              event['event'] == 'parallel.status' &&
              event['status'] == 'paused',
        )) {
          if (DateTime.now().isAfter(deadline)) {
            fail('publication did not settle');
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await Future<void>.delayed(Duration.zero);
      }
    },
  );

  test(
    'retry after initialization failure retains captured HTTP evidence',
    () async {
      var attempts = 0;
      fixture.downloader.onStart = () async {
        if (attempts++ == 0) {
          await fixture.downloader.emit(fixture.complete());
          throw StateError('transient startup failure');
        }
      };
      await expectLater(fixture.gateway.initialize(), throwsStateError);
      await fixture.gateway.initialize();
      final handle = (await fixture.gateway.attach(fixture.parent.taskId))!;
      expect(handle.current.transferredBytes, 4);
      expect((await fixture.partState())['complete'], isTrue);
      expect(fixture.verificationEvents, isEmpty);
    },
  );

  test(
    'startup status retention is bounded and live delivery resumes',
    () async {
      fixture.downloader.onStart = () async {
        final unknown = fixture.complete(
          child: fixture.child.copyWith(taskId: 'unknown.part.0'),
        );
        for (var index = 0; index < 5000; index++) {
          fixture.downloader.updatesController.add(unknown);
        }
        await fixture.downloader.emit(fixture.complete());
      };
      await fixture.gateway.initialize();
      expect(
        fixture.diagnostics.transportEvents.where(
          (event) => event['event'] == 'startup.statusBufferFull',
        ),
        hasLength(1),
      );
      expect(
        (await fixture.partState())['complete'],
        isFalse,
        reason:
            'Overflow must fall back to verification, never infer completion',
      );
      await fixture.downloader.emit(fixture.complete());
      await fixture.untilCompleted();
      expect((await fixture.partState())['complete'], isTrue);
      expect(fixture.verificationEvents, isEmpty);
    },
  );
}

final class _Fixture {
  _Fixture(
    this.root,
    this.paths,
    this.parent,
    this.child,
    this.file,
    this.manifest,
    this.downloader,
    this.gateway,
    this.diagnostics,
  );
  final Directory root;
  final _Paths paths;
  final ParallelDownloadTask parent;
  final DownloadTask child;
  final File file;
  final File manifest;
  final _Downloader downloader;
  final PackageBackgroundDownloaderGateway gateway;
  final InMemoryDownloadDiagnosticsV2 diagnostics;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('aw-startup-replay-');
    final paths = _Paths(root.path);
    PathProviderPlatform.instance = paths;
    final parent = ParallelDownloadTask(
      taskId: 'aw_v2_startup_test_g1',
      url: 'https://example.invalid/video',
      filename: 'video.mp4',
      directory: root.path,
      baseDirectory: BaseDirectory.root,
      group: kDownloadV2DurableParallelGroup,
      chunks: 2,
      allowPause: true,
    );
    final parts = await Directory('${await parent.filePath()}.parts').create();
    final children = [
      for (var index = 0; index < 2; index++)
        DownloadTask(
          taskId: '${parent.taskId}.part.$index',
          url: parent.url,
          filename: '$index.part',
          directory: parts.path,
          baseDirectory: BaseDirectory.root,
          group: 'animewitcher_parts',
          updates: Updates.statusAndProgress,
          headers: {'Range': 'bytes=${index * 4}-${index * 4 + 3}'},
          metaData: jsonEncode({
            'parentTaskId': parent.taskId,
            'attemptGeneration': 1,
          }),
        ),
    ];
    final file = await File(await children.first.filePath())
        .writeAsBytes([1, 2, 3, 4]);
    final manifest = await privateParallelManifestFileV2(parent);
    await manifest.parent.create(recursive: true);
    await manifest.writeAsString(
      jsonEncode({
        'schemaVersion': 7,
        'parentTaskId': parent.taskId,
        'parentTask': parent.toJson(),
        'generation': 1,
        'checkpointSequence': 1,
        'expectedBytes': 8,
        'totalBytes': 8,
        'parts': [
          for (var index = 0; index < 2; index++)
            {
              'task': children[index].toJson(),
              'from': index * 4,
              'to': index * 4 + 3,
              'progress': 0.0,
              'credibleProgress': 0.0,
              'durableBytes': 0,
              'complete': false,
              'attemptGeneration': 1,
            },
        ],
      }),
    );
    final downloader = _Downloader();
    await downloader.database.updateRecord(
      TaskRecord(parent, TaskStatus.paused, 0, 8),
    );
    final diagnostics = InMemoryDownloadDiagnosticsV2();
    final gateway = PackageBackgroundDownloaderGateway(
      downloader: downloader,
      isIOS: () => true,
      diagnostics: diagnostics,
      notificationPreferences: () => DownloadNotificationPrefs.disabled,
    );
    return _Fixture(
      root,
      paths,
      parent,
      children.first,
      file,
      manifest,
      downloader,
      gateway,
      diagnostics,
    );
  }

  TaskStatusUpdate complete({DownloadTask? child, int attempt = 1}) =>
      TaskStatusUpdate(
        (child ?? this.child).copyWith(
          metaData: jsonEncode({
            'parentTaskId': parent.taskId,
            'attemptGeneration': attempt,
          }),
        ),
        TaskStatus.complete,
        null,
        null,
        {'content-range': 'bytes 0-3/8', 'etag': '"resource"'},
        206,
      );
  List<Map<String, Object?>> get verificationEvents => diagnostics
      .transportEvents
      .where(
        (event) => (event['event'] as String).startsWith(
          'parallel.sourceVerification',
        ),
      )
      .toList();
  Future<Map<String, dynamic>> partState() async {
    final decoded = jsonDecode(await manifest.readAsString()) as Map;
    return Map<String, dynamic>.from((decoded['parts'] as List).first as Map);
  }

  Future<void> untilCompleted() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while ((await partState())['complete'] != true) {
      if (DateTime.now().isAfter(deadline)) {
        fail('completion was not persisted');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> dispose() async {
    await downloader.updatesController.close();
    downloader.database.destroy();
    await root.delete(recursive: true);
  }
}

final class _Downloader implements FileDownloader {
  _Downloader() : database = Database(_Storage()) {
    transfers = _Transfers(this);
  }
  @override
  final Database database;
  @override
  late Transfers transfers;
  final updatesController = StreamController<TaskUpdate>.broadcast();
  final native = <Task>[];
  Future<void> Function()? onConfigure;
  Future<void> Function()? onStart;
  Future<bool> Function()? onCancel;
  Future<void> emit(TaskUpdate update) async {
    updatesController.add(update);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Stream<TaskUpdate> get updates => updatesController.stream;
  @override
  Future<List<(String, String)>> configure({
    dynamic globalConfig,
    dynamic androidConfig,
    dynamic iOSConfig,
    dynamic desktopConfig,
  }) async {
    await onConfigure?.call();
    return [];
  }

  @override
  Future<void> start({
    bool doTrackTasks = true,
    bool markDownloadedComplete = true,
    bool doRescheduleKilledTasks = true,
    bool autoCleanDatabase = false,
  }) async => await onStart?.call();
  @override
  Future<List<Task>> allTasks({
    String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true,
    bool allGroups = false,
  }) async => native;
  @override
  Future<bool> cancelTasksWithIds(Iterable<String> ids) async =>
      await onCancel?.call() ?? true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Storage implements PersistentStorage {
  final records = <String, TaskRecord>{};
  @override
  Future<void> storeTaskRecord(TaskRecord record) async {
    records[record.taskId] = record;
  }

  @override
  Future<TaskRecord?> retrieveTaskRecord(String id) async => records[id];
  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async =>
      records.values.toList();
  @override
  Future<void> removeTaskRecord(String? id) async {
    if (id == null) {
      records.clear();
    } else {
      records.remove(id);
    }
  }

  @override
  Future<List<Task>> retrieveAllPausedTasks() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transfers implements Transfers {
  _Transfers(this.downloader);
  @override
  final _Downloader downloader;
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
  _Paths(this.root);
  final String root;
  Future<void> Function()? onSupport;
  @override
  Future<String?> getApplicationSupportPath() async {
    final callback = onSupport;
    onSupport = null;
    await callback?.call();
    return '$root/support';
  }

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}
