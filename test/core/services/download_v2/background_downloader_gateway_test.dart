import 'dart:convert';

import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadTaskSpecV2', () {
    test('one parent spec carries aggregate package parallelism only', () {
      const spec = DownloadTaskSpecV2(
        taskId: 'aw_v2_x_g1',
        url: 'https://example.invalid/video.mp4',
        destinationPath: 'downloads/a.mp4',
        headers: <String, String>{},
        allowPause: true,
        retries: 2,
        parallelChunks: 5,
      );

      expect(spec.taskId, 'aw_v2_x_g1');
      expect(spec.url, 'https://example.invalid/video.mp4');
      expect(spec.destinationPath, 'downloads/a.mp4');
      expect(spec.headers, isEmpty);
      expect(spec.allowPause, isTrue);
      expect(spec.retries, 2);
      expect(spec.parallelChunks, 5);
    });

    test('parallel chunk count must be positive', () {
      expect(
        () => DownloadTaskSpecV2(
          taskId: 'aw_v2_x_g1',
          url: 'https://example.invalid/video.mp4',
          destinationPath: 'downloads/a.mp4',
          headers: const <String, String>{},
          allowPause: true,
          retries: 2,
          parallelChunks: 0,
        ),
        throwsAssertionError,
      );
    });
  });

  test('transport handle contract exposes parent task identity only', () {
    const snapshot = DownloadTransportSnapshot(
      taskId: 'aw_v2_x_g1',
      status: DownloadTransportStatus.running,
      progress: 0.25,
      transferredBytes: 25,
      totalBytes: 100,
    );
    final handle = _FakeDownloadTransportHandle(snapshot);

    expect(handle.taskId, snapshot.taskId);
    expect(handle.current, same(snapshot));
    expect(handle.current.progress, 0.25);
  });

  test('package snapshot reads Transfer speed and ETA notifiers', () {
    final task = DownloadTask(
      taskId: 'aw_v2_metrics_g1',
      url: 'https://example.invalid/video.mp4',
      filename: 'video.mp4',
      updates: Updates.statusAndProgress,
      allowPause: true,
    );
    final transfer = Transfer(task);
    transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.running));
    transfer.updateProgress(
      TaskProgressUpdate(
        task,
        0.25,
        400,
        12.5,
        const Duration(seconds: 24),
      ),
    );

    final snapshot = packageTransportSnapshotForV2(
      transfer,
      totalBytes: 400,
    );

    expect(snapshot.status, DownloadTransportStatus.running);
    expect(snapshot.progress, 0.25);
    expect(snapshot.transferredBytes, 100);
    expect(snapshot.totalBytes, 400);
    expect(snapshot.networkSpeedMBps, 12.5);
    expect(snapshot.timeRemaining, const Duration(seconds: 24));
  });
  test('parallel parent ignores burst-derived package speed and ETA', () {
    final task = ParallelDownloadTask(
      taskId: 'aw_v2_parallel_speed_g1',
      url: 'https://example.invalid/video.mp4',
      filename: 'video.mp4',
      chunks: 16,
      updates: Updates.statusAndProgress,
      allowPause: true,
    );
    final transfer = Transfer(task);
    transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.running));
    transfer.updateProgress(
      TaskProgressUpdate(
        task,
        0.62,
        1200000000,
        212.9,
        const Duration(seconds: 2),
      ),
    );

    final snapshot = packageTransportSnapshotForV2(
      transfer,
      totalBytes: 1200000000,
    );

    expect(snapshot.status, DownloadTransportStatus.running);
    expect(snapshot.progress, 0.62);
    expect(snapshot.networkSpeedMBps, -1);
    expect(snapshot.timeRemaining, Duration.zero);
  });

  test('parallel parent progress promotes stale enqueued status to running', () {
    final task = ParallelDownloadTask(
      taskId: 'aw_v2_parallel_progress_g1',
      url: 'https://example.invalid/video.mp4',
      filename: 'video.mp4',
      chunks: 4,
      updates: Updates.statusAndProgress,
      allowPause: true,
    );
    final transfer = Transfer(task);
    transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.enqueued));
    transfer.updateProgress(
      TaskProgressUpdate(
        task,
        0.25,
        400,
        3.0,
        const Duration(seconds: 30),
      ),
    );

    final snapshot = packageTransportSnapshotForV2(
      transfer,
      totalBytes: 400,
    );

    expect(snapshot.status, DownloadTransportStatus.running);
    expect(snapshot.progress, 0.25);
    expect(snapshot.transferredBytes, 100);
  });

  test('iOS V2 keeps the requested width for durable ranged execution', () async {
    const spec = DownloadTaskSpecV2(
      taskId: 'aw_v2_ios_safe_resume_g1',
      url: 'https://example.invalid/video.mp4',
      destinationPath: 'downloads/video.mp4',
      headers: <String, String>{},
      allowPause: true,
      retries: 2,
      parallelChunks: 16,
    );

    final task = await packageTaskForV2(spec, isIOS: true);

    expect(effectivePackageParallelChunksV2(16, isIOS: true), 16);
    expect(effectivePackageParallelChunksV2(16, isIOS: false), 16);
    expect(task, isA<ParallelDownloadTask>());
    expect((task as ParallelDownloadTask).chunks, 16);
  });

  test('durable child cleanup selects only the exact V2 parent records', () {
    DownloadTask child(String id, String parent) => DownloadTask(
      taskId: id,
      url: 'https://example.invalid/video.mp4',
      filename: '$id.part',
      group: 'animewitcher_parts',
      metaData: '{"parentTaskId":"$parent"}',
    );

    final records = <TaskRecord>[
      TaskRecord(child('aw_v2_parent_g1.part.0', 'aw_v2_parent_g1'), TaskStatus.complete, 1, 10),
      TaskRecord(child('aw_v2_parent_g1.part.1', 'aw_v2_parent_g1'), TaskStatus.paused, .5, 10),
      TaskRecord(child('aw_v2_other_g1.part.0', 'aw_v2_other_g1'), TaskStatus.complete, 1, 10),
      TaskRecord(
        DownloadTask(
          taskId: 'aw_v2_parent_g1',
          url: 'https://example.invalid/video.mp4',
          filename: 'video.mp4',
          group: kDownloadV2DurableParallelGroup,
        ),
        TaskStatus.complete,
        1,
        20,
      ),
    ];

    expect(
      durableChildTaskIdsForParentV2(records, 'aw_v2_parent_g1'),
      <String>[
        'aw_v2_parent_g1.part.0',
        'aw_v2_parent_g1.part.1',
      ],
    );
  });

  test('durable snapshot reports configured and live connection width', () {
    final snapshot = durableParallelInitialSnapshotV2(
      taskId: 'aw_v2_width_g1',
      initialStatus: DownloadTransportStatus.running,
      totalBytes: 100,
      restoredProgress: .25,
      durableBytes: 25,
      configuredConnections: 16,
      activeConnections: 4,
    );

    expect(snapshot.configuredConnections, 16);
    expect(snapshot.activeConnections, 4);
  });

  test('live durable-parent snapshot publishes live bytes every progress tick', () {
    final snapshot = durableParallelLiveSnapshotV2(
      taskId: 'aw_v2_live_g1',
      liveProgress: .25,
      totalBytes: 400,
      durableBytes: 25,
      parentActive: true,
      configuredConnections: 1,
      activeConnections: 1,
      networkSpeedMBps: 2,
      timeRemaining: const Duration(seconds: 3),
    );

    expect(snapshot.status, DownloadTransportStatus.running);
    expect(snapshot.progress, .25);
    expect(
      snapshot.transferredBytes,
      100,
      reason:
          'active presentation must follow live URLSession progress instead of '
          'waiting for the next immutable checkpoint',
    );
    expect(snapshot.networkSpeedMBps, 2);
  });

  test('durable native ownership excludes package-paused children', () {
    DownloadTask child(String id) => DownloadTask(
      taskId: id,
      url: 'https://example.invalid/video.mp4',
      filename: '$id.part',
      group: 'animewitcher_parts',
    );
    final running = child('running-child');
    final paused = child('paused-child');
    final unrelated = DownloadTask(
      taskId: 'unrelated',
      url: 'https://example.invalid/other.mp4',
      filename: 'other.mp4',
      group: 'downloads',
    );

    expect(
      activeDurablePartTaskIdsV2(
        packageTasks: <Task>[running, paused, unrelated],
        pausedTasks: <Task>[paused],
      ),
      <String>{running.taskId},
      reason:
          'background_downloader allTasks also contains stored paused tasks; '
          'those must not reserve the only native writer after relaunch',
    );
  });

  test('durable range drain keeps parent paused while bytes still settle', () {
    expect(
      durableParallelProgressStatusV2(progress: 0.5, parentActive: false),
      DownloadTransportStatus.paused,
    );
    expect(
      durableParallelProgressStatusV2(progress: 0.5, parentActive: true),
      DownloadTransportStatus.running,
    );
    expect(
      durableParallelProgressStatusV2(progress: 1, parentActive: false),
      DownloadTransportStatus.complete,
    );
    expect(
      durableParallelProgressStatusV2(progress: 1, parentActive: true),
      DownloadTransportStatus.running,
    );
  });

  test('completed durable parent rehydrates complete after manifest cleanup', () {
    final snapshot = durableParallelInitialSnapshotV2(
      taskId: 'aw_v2_complete_g1',
      initialStatus: DownloadTransportStatus.complete,
      totalBytes: 100,
      restoredProgress: null,
      durableBytes: null,
    );

    expect(snapshot.status, DownloadTransportStatus.complete);
    expect(snapshot.progress, 1);
    expect(snapshot.transferredBytes, 100);
    expect(snapshot.totalBytes, 100);
  });

  test('iOS range probe accepts RFC-valid Content-Range formatting', () {
    expect(
      parseRangeProbeTotalBytesV2('bytes 0-0/391600000'),
      391600000,
    );
    expect(
      parseRangeProbeTotalBytesV2('Bytes 0 - 0 / 391600000'),
      391600000,
    );
    expect(parseRangeProbeTotalBytesV2('bytes 1-1/391600000'), isNull);
    expect(parseRangeProbeTotalBytesV2('bytes 0-0/*'), isNull);
    expect(parseRangeProbeTotalBytesV2(null), isNull);
  });

  test('V2 package task carries long user-initiated transfer hints', () async {
    const spec = DownloadTaskSpecV2(
      taskId: 'aw_v2_hints_g1',
      url: 'https://example.invalid/video.mp4',
      destinationPath: 'downloads/video.mp4',
      headers: <String, String>{},
      allowPause: true,
      retries: 2,
      parallelChunks: 4,
    );

    final task = await packageTaskForV2(spec);

    expect(task.group, kDownloadV2PackageGroup);
    expect(task.displayName, 'video.mp4');
    expect(task.transferHints, contains(TransferHint.largeFile));
    expect(task.transferHints, contains(TransferHint.userInitiated));
    expect(task.priority, 0);
  });

  test('V2 notification preferences configure the package group', () async {
    final downloader = FileDownloader();
    const prefs = DownloadNotificationPrefs(
      running: false,
      complete: true,
      paused: true,
      canceled: false,
      error: true,
    );
    await configurePackageNotificationsV2(downloader, prefs);
    final task = await packageTaskForV2(
      const DownloadTaskSpecV2(
        taskId: 'aw_v2_notifications_g1',
        url: 'https://example.invalid/video.mp4',
        destinationPath: 'downloads/video.mp4',
        headers: <String, String>{},
        allowPause: true,
        retries: 2,
        parallelChunks: 1,
      ),
    );

    final config = downloader.notificationConfigForTask(task);
    expect(config, isNotNull);
    expect(config!.running, isNull);
    expect(config.complete, isNotNull);
    expect(config.paused, isNotNull);
    expect(config.canceled, isNull);
    expect(config.error, isNotNull);
  });
  test('all-off notifications use a silent non-UIDT package group', () async {
    final downloader = FileDownloader();
    await configurePackageNotificationsV2(
      downloader,
      DownloadNotificationPrefs.disabled,
    );
    final task = await packageTaskForV2(
      const DownloadTaskSpecV2(
        taskId: 'aw_v2_silent_g1',
        url: 'https://example.invalid/video.mp4',
        destinationPath: 'downloads/video.mp4',
        headers: <String, String>{},
        allowPause: true,
        retries: 2,
        parallelChunks: 1,
      ),
      userInitiated: false,
      group: kDownloadV2SilentPackageGroup,
    );

    expect(task.group, kDownloadV2SilentPackageGroup);
    expect(task.transferHints, contains(TransferHint.largeFile));
    expect(task.transferHints, isNot(contains(TransferHint.userInitiated)));
    expect(task.priority, isNot(0));
    expect(downloader.notificationConfigForTask(task), isNull);
  });

  test('gateway initialization retries after one package start failure', () async {
    var startCalls = 0;
    final gateway = PackageBackgroundDownloaderGateway(
      initializePackage: () async {
        startCalls++;
        if (startCalls == 1) {
          throw StateError('transient package start failure');
        }
      },
    );

    await expectLater(gateway.initialize(), throwsStateError);
    await gateway.initialize();

    expect(startCalls, 2);
  });

  test('parallel resume waits until every package child has resume data', () async {
    final parent = ParallelDownloadTask(
      taskId: 'aw_v2_parallel_resume_g1',
      url: 'https://example.invalid/video.mp4',
      filename: 'video.mp4',
      chunks: 2,
      allowPause: true,
    );
    final child1 = DownloadTask(
      taskId: 'child-1',
      url: 'https://example.invalid/video.mp4',
      filename: 'part-1',
      allowPause: true,
    );
    final child2 = DownloadTask(
      taskId: 'child-2',
      url: 'https://example.invalid/video.mp4',
      filename: 'part-2',
      allowPause: true,
    );
    final parentData = ResumeData(
      parent,
      jsonEncode(<Object?>[
        <String, Object?>{
          'task': <String, Object?>{'taskId': child1.taskId},
        },
        <String, Object?>{
          'task': <String, Object?>{'taskId': child2.taskId},
        },
      ]),
    );
    var child2Lookups = 0;

    final ready = await waitForPackageParallelResumeDataV2(
      task: parent,
      retrieveResumeData: (taskId) async {
        if (taskId == parent.taskId) return parentData;
        if (taskId == child1.taskId) return ResumeData(child1, 'ready');
        if (taskId == child2.taskId) {
          child2Lookups++;
          return child2Lookups >= 3 ? ResumeData(child2, 'ready') : null;
        }
        return null;
      },
      maxAttempts: 4,
      delay: (_) async {},
    );

    expect(ready, isTrue);
    expect(child2Lookups, 3);
  });

  test('parallel resume stays paused when package child resume data never settles', () async {
    final parent = ParallelDownloadTask(
      taskId: 'aw_v2_parallel_resume_timeout_g1',
      url: 'https://example.invalid/video.mp4',
      filename: 'video.mp4',
      chunks: 2,
      allowPause: true,
    );
    final parentData = ResumeData(
      parent,
      jsonEncode(<Object?>[
        <String, Object?>{
          'task': <String, Object?>{'taskId': 'child-1'},
        },
        <String, Object?>{
          'task': <String, Object?>{'taskId': 'child-2'},
        },
      ]),
    );

    final ready = await waitForPackageParallelResumeDataV2(
      task: parent,
      retrieveResumeData: (taskId) async =>
          taskId == parent.taskId ? parentData : null,
      maxAttempts: 2,
      delay: (_) async {},
    );

    expect(ready, isFalse);
  });

  test('package notFound maps to missing transport instead of failure', () {
    expect(
      transportStatusFromPackage(
        TaskStatus.notFound,
        TransferHoldReason.none,
      ),
      DownloadTransportStatus.missing,
    );
  });
}

final class _FakeDownloadTransportHandle implements DownloadTransportHandle {
  _FakeDownloadTransportHandle(this.current);

  @override
  final DownloadTransportSnapshot current;

  @override
  String get taskId => current.taskId;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => const Stream.empty();

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async => true;
}

