import 'package:background_downloader/background_downloader.dart';

/// Package-neutral presentation values projected from the V2 parent transfer.
///
/// Deliberately carries no speed or remaining-time values: per-download
/// throughput is never displayed. The one speed the app shows is the session
/// total published by the continued-processing observer.
class DownloadProgressData {
  const DownloadProgressData({
    required this.taskId,
    required this.progress,
    required this.status,
    this.totalSize = -1,
    this.completedPages,
    this.totalPages,
  });

  final String taskId;
  final double progress;
  final int totalSize;
  final int? completedPages;
  final int? totalPages;
  final TaskStatus status;
}
