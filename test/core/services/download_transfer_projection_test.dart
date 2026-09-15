import 'package:animewitcher/core/services/download_transfer_projection.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final task = DownloadTask(
    taskId: 'episode-telemetry',
    url: 'https://example.test/video.mp4',
    filename: 'episode.mp4',
  );

  test('plugin speed and ETA remain authoritative while running', () {
    final projected = projectTransferTelemetry(
      task: task,
      status: TaskStatus.running,
      progress: 0.25,
      networkSpeedMbPerSecond: 6.5,
      timeRemaining: const Duration(seconds: 20),
      totalSize: 400000000,
    );

    expect(projected.taskId, task.taskId);
    expect(projected.progress, 0.25);
    expect(projected.networkSpeed, 6.5);
    expect(projected.timeRemaining, const Duration(seconds: 20));
    expect(projected.totalSize, 400000000);
    expect(projected.status, TaskStatus.running);
  });

  test('paused plugin transfer never exposes stale speed or ETA', () {
    final projected = projectTransferTelemetry(
      task: task,
      status: TaskStatus.paused,
      progress: 0.5,
      networkSpeedMbPerSecond: 9.25,
      timeRemaining: const Duration(seconds: 8),
      totalSize: 400000000,
    );

    expect(projected.progress, 0.5);
    expect(projected.networkSpeed, 0);
    expect(projected.timeRemaining, Duration.zero);
    expect(projected.status, TaskStatus.paused);
  });

  test('invalid plugin speed is normalized without inventing throughput', () {
    final projected = projectTransferTelemetry(
      task: task,
      status: TaskStatus.running,
      progress: 0.75,
      networkSpeedMbPerSecond: double.nan,
      timeRemaining: const Duration(seconds: 4),
      totalSize: 400000000,
    );

    expect(projected.networkSpeed, 0);
    expect(projected.timeRemaining, const Duration(seconds: 4));
  });
}
