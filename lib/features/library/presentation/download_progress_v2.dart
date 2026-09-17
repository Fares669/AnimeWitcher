import 'package:background_downloader/background_downloader.dart';

/// Ephemeral presentation metrics for one V2 parent transfer.
///
/// This mirrors only user-visible aggregate state. Package-created child
/// transfers remain opaque and no metric here is persisted as transport state.
final class DownloadProgressData {
  const DownloadProgressData({
    required this.taskId,
    required this.progress,
    required this.networkSpeed,
    required this.timeRemaining,
    required this.totalSize,
    required this.status,
  });

  final String taskId;
  final double progress;
  final double networkSpeed;
  final Duration timeRemaining;
  final int totalSize;
  final TaskStatus status;
}
