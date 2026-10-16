import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/parallel_download_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _LifecycleBoundaryFixture fixture;
  setUp(() async => fixture = await _LifecycleBoundaryFixture.create());
  tearDown(() async => fixture.dispose());

  test(
    'immediate resume waits for an in-flight pause before replacing its writer',
    () async {
      expect(await fixture.coordinator.start(fixture.parent, 8), isTrue);
      final previous = fixture.starts.single;
      fixture.pauseGate = Completer<void>();
      final paused = fixture.coordinator.pause(fixture.parent);
      await fixture.pauseEntered.future.timeout(const Duration(seconds: 2));
      var resumed = false;
      final resume = fixture.coordinator.start(fixture.parent, 8).then((
        accepted,
      ) {
        resumed = true;
        return accepted;
      });

      try {
        await Future<void>.delayed(Duration.zero);
        expect(resumed, isFalse);
        expect(fixture.starts, hasLength(1));
        expect(fixture.live, {previous.taskId});
        expect(fixture.coordinator.activeConnectionCount, 1);
      } finally {
        fixture.pauseGate!.complete();
        await paused;
        await resume;
      }

      expect(await paused, isTrue);
      expect(await resume, isTrue);
      expect(fixture.starts, hasLength(2));
      final current = fixture.starts.last;
      expect(current.taskId, previous.taskId);
      expect(_attempt(current), greaterThan(_attempt(previous)));
      expect(fixture.coordinator.isActive(fixture.parent.taskId), isTrue);
      expect(fixture.coordinator.activeConnectionCount, 1);
    },
  );

  for (final staleStatus in [TaskStatus.complete, TaskStatus.failed]) {
    test(
      'old-attempt ${staleStatus.name} cannot settle or park the resumed writer',
      () async {
        expect(await fixture.coordinator.start(fixture.parent, 8), isTrue);
        final previous = fixture.starts.single;
        expect(await fixture.coordinator.pause(fixture.parent), isTrue);
        expect(await fixture.coordinator.start(fixture.parent, 8), isTrue);
        final current = fixture.starts.last;
        expect(_attempt(current), greaterThan(_attempt(previous)));
        fixture.coordinator.handleUpdate(
          TaskStatusUpdate(current, TaskStatus.running),
        );
        fixture.coordinator.handleUpdate(TaskProgressUpdate(current, 0.25, 8));
        await fixture.barrier();
        fixture.statuses.clear();

        fixture.coordinator.handleUpdate(
          TaskStatusUpdate(
            previous,
            staleStatus,
            staleStatus == TaskStatus.failed
                ? TaskHttpException('expired old source', 403)
                : null,
          ),
        );
        fixture.coordinator.handleUpdate(TaskProgressUpdate(previous, 0.9, 8));
        await fixture.barrier();

        expect(fixture.coordinator.isActive(fixture.parent.taskId), isTrue);
        expect(fixture.coordinator.activeConnectionCount, 1);
        expect(fixture.coordinator.progressFor(fixture.parent.taskId), 0.25);
        expect(fixture.statuses, isNot(contains(TaskStatus.paused)));
        expect(fixture.statuses, isNot(contains(TaskStatus.complete)));
        expect(fixture.starts, hasLength(2));
        expect(await File(await fixture.parent.filePath()).exists(), isFalse);

        final bytes = List<int>.generate(8, (i) => i);
        await File(await current.filePath()).writeAsBytes(bytes, flush: true);
        fixture.live.remove(current.taskId);
        fixture.coordinator.handleUpdate(
          TaskStatusUpdate(current, TaskStatus.complete).copyWith(
            responseStatusCode: 206,
            responseHeaders: {'Content-Range': 'bytes 0-7/8'},
          ),
        );
        await fixture.barrier();
        expect(
          fixture.records[fixture.parent.taskId]?.status,
          TaskStatus.complete,
        );
        expect(
          await File(await fixture.parent.filePath()).readAsBytes(),
          bytes,
        );
        expect(fixture.starts, hasLength(2));
      },
    );
  }
}

int _attempt(DownloadTask task) =>
    (jsonDecode(task.metaData) as Map)['attemptGeneration'] as int;

class _LifecycleBoundaryFixture {
  _LifecycleBoundaryFixture(this.directory) {
    parent = ParallelDownloadTask(
      taskId: 'lifecycle-boundary',
      url: 'https://example.test/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 1,
      allowPause: true,
    );
    coordinator = PersistentParallelDownload(
      verifyPartSource: verifiedSavedTestRange,
      promoteFile: publishCompletedTestFile,
      startPart: (task, _, _) async {
        expect(
          live,
          isNot(contains(task.taskId)),
          reason: 'a range must have only one native writer',
        );
        starts.add(task);
        live.add(task.taskId);
        return true;
      },
      pausePart: (task) async {
        if (!pauseEntered.isCompleted) pauseEntered.complete();
        await pauseGate?.future;
        live.remove(task.taskId);
      },
      cancelParts: (ids) async => live.removeAll(ids),
      saveRecord: (record) async {
        records[record.taskId] = record;
      },
      recordForId: (id) async => records[id],
      onUpdate: (update) {
        if (update is TaskStatusUpdate) statuses.add(update.status);
      },
      onPartProgress: (_, _, _) {},
      livePartIds: () async => Set<String>.from(live),
      recoveryDelay: const Duration(days: 1),
      diskProgressPollInterval: const Duration(days: 1),
      pendingStartLeaseDelay: const Duration(days: 1),
      tailStallDelay: const Duration(days: 1),
    );
  }

  final Directory directory;
  late final ParallelDownloadTask parent;
  late final PersistentParallelDownload coordinator;
  final starts = <DownloadTask>[];
  final live = <String>{};
  final records = <String, TaskRecord>{};
  final statuses = <TaskStatus>[];
  final pauseEntered = Completer<void>();
  Completer<void>? pauseGate;

  static Future<_LifecycleBoundaryFixture> create() async =>
      _LifecycleBoundaryFixture(
        await Directory.systemTemp.createTemp('parallel-lifecycle-boundary-'),
      );

  Future<void> barrier() =>
      coordinator.reconcile(() async => Set<String>.from(live));

  Future<void> dispose() async {
    if (pauseGate != null && !pauseGate!.isCompleted) pauseGate!.complete();
    await coordinator.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
