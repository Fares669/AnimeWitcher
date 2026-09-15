import 'package:background_downloader/background_downloader.dart';

/// UI-facing projection of one logical episode transfer.
///
/// [networkSpeed] is expressed in MB/s, matching background_downloader's
/// TaskProgressUpdate contract. A negative running value may still represent
/// an intentional "calculating" sentinel from a legacy projection.
class DownloadProgressData {
  final String taskId;
  final double progress;
  final double networkSpeed; // MB/s
  final Duration timeRemaining;
  final int totalSize; // Bytes
  final TaskStatus status;

  DownloadProgressData({
    required this.taskId,
    required double progress,
    required this.networkSpeed,
    required this.timeRemaining,
    required this.status,
    this.totalSize = -1,
  }) : progress = progress.clamp(0.0, 1.0);

  String get speedString {
    if (status == TaskStatus.paused) return 'متوقف';
    if (progress >= 1.0) return 'اكتمل';
    if (networkSpeed < 0) return 'جارٍ الحساب…';
    if (networkSpeed == 0) return '0 MB/s';

    if (networkSpeed < 1.0) {
      return '${(networkSpeed * 1000).toStringAsFixed(2)} KB/s';
    }
    return '${networkSpeed.toStringAsFixed(2)} MB/s';
  }
}

/// Projects background_downloader telemetry without re-estimating it.
///
/// While the plugin reports a live transfer, its speed (already MB/s) and ETA
/// are authoritative. Non-running states deliberately clear speed/ETA so stale
/// native values cannot survive a pause/final state in the UI.
DownloadProgressData projectTransferTelemetry({
  required Task task,
  required TaskStatus status,
  required double progress,
  required double networkSpeedMbPerSecond,
  required Duration timeRemaining,
  required int totalSize,
}) {
  final running = status == TaskStatus.running;
  final speed = running && networkSpeedMbPerSecond.isFinite
      ? networkSpeedMbPerSecond
      : 0.0;
  final eta = running && !timeRemaining.isNegative
      ? timeRemaining
      : Duration.zero;
  return DownloadProgressData(
    taskId: task.taskId,
    progress: progress,
    networkSpeed: speed,
    timeRemaining: eta,
    totalSize: totalSize,
    status: status,
  );
}
