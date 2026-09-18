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


