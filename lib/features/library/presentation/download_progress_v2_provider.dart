import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/download_v2/download_v2_identity.dart';
import '../../../core/services/download_v2/download_v2_provider.dart';
import '../../../core/utils/download_time_remaining.dart' show DownloadProgressData;
import 'downloads_provider.dart';

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
  final trackingOwners = <String, String?>{};

  for (final item in downloads) {
    final logicalId = item.logicalId?.trim();
    if (logicalId == null || logicalId.isEmpty) continue;
    final snapshot = manager?.snapshotFor(DownloadLogicalId(logicalId));
    final progress = (snapshot?.progress ?? item.progress).clamp(0.0, 1.0);
    final key = logicalId;

    result[key] = DownloadProgressData(
      taskId: item.id,
      progress: progress.toDouble(),
      networkSpeed: snapshot?.networkSpeedMBps ?? -1,
      timeRemaining: snapshot?.timeRemaining ?? Duration.zero,
      totalSize: snapshot?.totalBytes ?? item.totalBytes ?? -1,
      status: item.status,
    );

    // Temporary read-only compatibility for callers that have not yet moved
    // from tracking URL to logical identity. Never create an alias when two
    // logical variants share the same tracking URL; that would reintroduce the
    // collision this provider is intended to eliminate.
    final trackingAlias = item.trackingUrl.trim();
    if (trackingAlias.isNotEmpty) {
      if (!trackingOwners.containsKey(trackingAlias)) {
        trackingOwners[trackingAlias] = logicalId;
      } else if (trackingOwners[trackingAlias] != logicalId) {
        trackingOwners[trackingAlias] = null;
      }
    }
  }

  for (final entry in trackingOwners.entries) {
    final owner = entry.value;
    if (owner == null) continue;
    final data = result[owner];
    if (data != null) result[entry.key] = data;
  }

  return Map<String, DownloadProgressData>.unmodifiable(result);
});

/// V2 deliberately keeps package child transfers opaque. The existing progress
/// widget renders aggregate parent progress, so this compatibility projection
/// remains empty rather than exposing package-managed chunk identity.
final downloadChunkProgressProvider = Provider<Map<String, Map<String, double>>>(
  (_) => const <String, Map<String, double>>{},
);
