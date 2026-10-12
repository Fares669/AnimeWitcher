import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final unknown in [false, true]) {
    test('gateway ${unknown ? 'unknown native settlement' : 'negative cancel ACK'} preserves owned range bytes and checkpoint', () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.downloader.cancelAccepted = unknown;
      f.downloader.unknownLiveness = unknown;
      await expectLater(f.handle.cancel(), throwsA(isA<StateError>()));
      expect(f.handle.current.status, isNot(DownloadTransportStatus.canceled));
      expect(await f.manifest.exists(), isTrue);
      expect(await f.part.readAsBytes(), [1, 2]);
      if (!unknown) expect(f.downloader.native.map((task) => task.taskId), contains(f.child.taskId));
    });
  }

  test('gateway accepted cancel waits for raw native writer settlement before range cleanup', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.downloader.keepCanceledWriterLive = true;
    var finished = false;
    final cancellation = f.handle.cancel().whenComplete(() => finished = true);
    try {
      await f.downloader.cancelEntered.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(finished, isFalse, reason: 'package acceptance cannot authorize range/checkpoint deletion');
      expect(f.handle.current.status, isNot(DownloadTransportStatus.canceled));
      expect(f.downloader.native.map((task) => task.taskId), contains(f.child.taskId));
      expect(await f.part.readAsBytes(), [1, 2]);
      expect(await f.manifest.exists(), isTrue);
    } finally {
      f.downloader.keepCanceledWriterLive = false;
      f.downloader.native.clear();
      await cancellation;
    }
    expect(finished, isTrue);
    expect(f.handle.current.status, DownloadTransportStatus.canceled);
    expect(await f.manifest.exists(), isFalse);
  });

  for (final completed in [true, false]) {
    test('gateway restores exact ${completed ? 'complete' : 'incomplete'} durable parent without a manifest', () async {
      final root = await Directory.systemTemp.createTemp('aw-gateway-no-manifest-');
      final downloader = _Downloader();
      final parent = _parent(root);
      await File(await parent.filePath()).writeAsBytes(List<int>.filled(8, 7));
      await downloader.database.updateRecord(TaskRecord(
        parent, completed ? TaskStatus.complete : TaskStatus.paused, completed ? 1 : .5, 8,
      ));
      final gateway = _gateway(downloader);
      final handle = (await gateway.attach(parent.taskId))!;
      try {
        expect(handle.current.status, completed ? DownloadTransportStatus.complete : DownloadTransportStatus.missing);
        expect(await File(await parent.filePath()).readAsBytes(), List<int>.filled(8, 7));
        expect(downloader.cancelCalls, 0);
        expect(await Directory('${await parent.filePath()}.parts').exists(), isFalse);
      } finally {
        await handle.cancel();
        await downloader.updatesController.close();
        downloader.database.destroy();
        await root.delete(recursive: true);
      }
    });
  }

  for (final ios in [false, true]) {
    test('gateway injected iOS=$ios preserves only the platform-authoritative package parallel metrics', () async {
      final downloader = _Downloader();
      final task = ParallelDownloadTask(
        taskId: 'ordinary-parallel-metrics', url: 'https://example.test/video',
        filename: 'video.mp4', chunks: 2, group: kDownloadV2PackageGroup,
      );
      final transfer = Transfer(task, downloader);
      transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.running));
      transfer.updateProgress(TaskProgressUpdate(task, .25, 400, 12.5, const Duration(seconds: 24)));
      downloader.testTransfers.handles[task.taskId] = transfer;
      final gateway = _gateway(downloader, ios: ios);
      try {
        final handle = (await gateway.attach(task.taskId))!;
        expect(handle.current.networkSpeedMBps, ios ? -1 : 12.5);
        expect(handle.current.timeRemaining, ios ? Duration.zero : const Duration(seconds: 24));
        expect(handle.current.status, DownloadTransportStatus.running);
        expect(handle.current.progress, .25);
        expect(handle.current.transferredBytes, isNull);
      } finally {
        await gateway.removeTracking(task.taskId);
        await downloader.updatesController.close();
        downloader.database.destroy();
      }
    });
  }

  test('ordinary package HTTP404 is terminal source expiry rather than missing local identity', () {
    final task = DownloadTask(taskId: 'http404-exact-task', url: 'https://example.test/video', filename: 'video.mp4');
    final transfer = Transfer(task);
    try {
      transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.notFound));
      final snapshot = packageTransportSnapshotForV2(transfer);
      expect(snapshot.status, DownloadTransportStatus.failed);
      expect(snapshot.failureCategory, DownloadFailureCategory.sourceExpired);
    } finally {
      transfer.dispose();
    }
  });
}

PackageBackgroundDownloaderGateway _gateway(_Downloader downloader, {bool ios = true}) =>
    PackageBackgroundDownloaderGateway(
      downloader: downloader, initializePackage: () async {}, isIOS: () => ios,
      notificationPreferences: () => DownloadNotificationPrefs.disabled,
    );

ParallelDownloadTask _parent(Directory root) => ParallelDownloadTask(
  taskId: 'gateway-owned-parent', url: 'https://example.test/video', filename: 'video.mp4',
  directory: root.path, baseDirectory: BaseDirectory.root,
  group: kDownloadV2DurableParallelGroup, chunks: 2, allowPause: true,
);

final class _Fixture {
  _Fixture(this.root, this.downloader, this.child, this.part, this.manifest, this.handle);
  final Directory root;
  final _Downloader downloader;
  final DownloadTask child;
  final File part;
  final File manifest;
  final DownloadTransportHandle handle;
  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp('aw-gateway-owned-range-');
    final parent = _parent(root);
    final parts = await Directory('${await parent.filePath()}.parts').create();
    final children = [
      for (var index = 0; index < 2; index++) DownloadTask(
        taskId: '${parent.taskId}.part.$index', url: parent.url, filename: '$index.part',
        directory: parts.path, baseDirectory: BaseDirectory.root, group: 'animewitcher_parts',
        headers: {'Range': 'bytes=${index * 4}-${index * 4 + 3}'},
        metaData: jsonEncode({'parentTaskId': parent.taskId}),
      ),
    ];
    final part = await File(await children.first.filePath()).writeAsBytes([1, 2]);
    final manifest = await File(p.join(parts.path, 'manifest.json')).writeAsString(jsonEncode({
      'schemaVersion': 2, 'parentTaskId': parent.taskId, 'generation': 1,
      'checkpointSequence': 1, 'expectedBytes': 8, 'totalBytes': 8,
      'parts': [
        for (var index = 0; index < 2; index++) {
          'task': children[index].toJson(), 'from': index * 4, 'to': index * 4 + 3,
          'progress': index == 0 ? .5 : 0, 'credibleProgress': index == 0 ? .5 : 0,
          'durableBytes': 0, 'complete': false, 'attemptGeneration': 1,
        },
      ],
    }));
    final downloader = _Downloader()..native.add(children.first);
    await downloader.database.updateRecord(TaskRecord(parent, TaskStatus.paused, .25, 8));
    final handle = (await _gateway(downloader).attach(parent.taskId))!;
    return _Fixture(root, downloader, children.first, part, manifest, handle);
  }
  Future<void> dispose() async {
    downloader.cancelAccepted = true;
    downloader.keepCanceledWriterLive = false;
    downloader.unknownLiveness = false;
    downloader.native.clear();
    await handle.cancel();
    await downloader.updatesController.close();
    downloader.database.destroy();
    await root.delete(recursive: true);
  }
}

final class _Downloader implements FileDownloader {
  _Downloader() : database = Database(_Storage()) { transfers = _Transfers(this); }
  @override
  final Database database;
  @override
  late Transfers transfers;
  _Transfers get testTransfers => transfers as _Transfers;
  final updatesController = StreamController<TaskUpdate>.broadcast();
  final native = <Task>[];
  bool cancelAccepted = true;
  bool keepCanceledWriterLive = false;
  bool unknownLiveness = false;
  int cancelCalls = 0;
  final cancelEntered = Completer<void>();
  @override
  Stream<TaskUpdate> get updates => updatesController.stream;
  @override
  Future<bool> cancelTasksWithIds(Iterable<String> taskIds) async {
    cancelCalls++;
    if (!cancelEntered.isCompleted) cancelEntered.complete();
    if (cancelAccepted && !keepCanceledWriterLive) native.removeWhere((task) => taskIds.contains(task.taskId));
    return cancelAccepted;
  }
  @override
  Future<List<Task>> allTasks({String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true, bool allGroups = false,
  }) async {
    if (unknownLiveness) throw StateError('test-only raw native ownership unavailable');
    return [for (final task in native) if (allGroups || task.group == group) task];
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transfers implements Transfers {
  _Transfers(this.downloader);
  @override
  final _Downloader downloader;
  final handles = <String, Transfer>{};
  @override
  Transfer? forId(String taskId) => handles[taskId];
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
  Future<List<Task>> retrieveAllPausedTasks() async => [];
  @override
  Future<void> removeResumeData(String? id) async {}
  @override
  Future<void> removePausedTask(String? id) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
