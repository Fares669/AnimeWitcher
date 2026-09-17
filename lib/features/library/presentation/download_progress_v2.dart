import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'downloads_provider.dart';

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

/// Projects the V2 logical download list into the keyed shape used by the
/// existing download cards. The source of truth remains DownloadManagerV2.
final downloadProgressProvider = Provider<Map<String, DownloadProgressData>>((
  ref,
) {
  final downloads = ref.watch(downloadsProvider).value ?? const <DownloadItem>[];
  return <String, DownloadProgressData>{
    for (final item in downloads)
      if (item.trackingUrl.isNotEmpty)
        item.trackingUrl: DownloadProgressData(
          taskId: item.id,
          progress: item.progress,
          networkSpeed: item.networkSpeedMBps,
          timeRemaining: item.timeRemaining,
          totalSize: item.totalBytes ?? -1,
          status: item.status,
        ),
  };
});

/// V2 deliberately does not expose package-managed child chunk identities.
/// SegmentedDownloadProgress already renders parent aggregate progress, so the
/// compatibility map stays empty rather than rebuilding a second chunk model.
final downloadChunkProgressProvider =
    Provider<Map<String, Map<String, double>>>((ref) => const {});
