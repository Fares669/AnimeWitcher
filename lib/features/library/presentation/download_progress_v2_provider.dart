import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/download_v2/download_v2_identity.dart';
import '../../../core/services/download_v2/download_v2_provider.dart';
import 'downloads_provider.dart';

/// Package-neutral presentation data for the downloads library.
///
/// Values are projected from the V2 parent snapshot only. No V1 executor,
/// package database row, or child-chunk state is consulted.
class DownloadProgressData {
  const DownloadProgressData({
    required this.taskId,
    required this.progress,
    required this.networkSpeed,
    required this.timeRemaining,
    required this.status,
    this.totalSize = -1,
  });

  final String taskId;
  final double progress;
  final double networkSpeed;
  final Duration timeRemaining;
  final int totalSize;
  final TaskStatus status;
}

final downloadProgressProvider = Provider<Map<String, DownloadProgressData>>((
  ref,
) {
  final downloads = ref.watch(downloadsProvider).value ?? const <DownloadItem>[];
  final manager = downloads.any(
    (item) => item.logicalId?.trim().isNotEmpty == true,
  )
      ? ref.read(downloadManagerV2Provider)
      : null;
  final result = <String, DownloadProgressData>{};

  for (final item in downloads) {
    final logicalId = item.logicalId?.trim();
    final snapshot = logicalId == null || logicalId.isEmpty
        ? null
        : manager?.snapshotFor(DownloadLogicalId(logicalId));
    final progress = (snapshot?.progress ?? item.progress).clamp(0.0, 1.0);
    final key = item.trackingUrl.trim();
    if (key.isEmpty) continue;

    result[key] = DownloadProgressData(
      taskId: item.id,
      progress: progress.toDouble(),
      networkSpeed: snapshot?.networkSpeedMBps ?? -1,
      timeRemaining: snapshot?.timeRemaining ?? Duration.zero,
      totalSize: snapshot?.totalBytes ?? item.totalBytes ?? -1,
      status: item.status,
    );
  }

  return Map<String, DownloadProgressData>.unmodifiable(result);
});

/// V2 deliberately keeps package child transfers opaque. The existing progress
/// widget renders aggregate parent progress, so this compatibility projection
/// remains empty rather than exposing package-managed chunk identity.
final downloadChunkProgressProvider = Provider<Map<String, Map<String, double>>>(
  (_) => const <String, Map<String, double>>{},
);
