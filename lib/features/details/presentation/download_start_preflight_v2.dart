import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/storage/settings_repository.dart';
import '../../skip/data/aniskip_service.dart';
import '../../skip/data/mal_id_resolver.dart';
import '../../skip/data/skip_segment_cache.dart';

/// Preserves the non-transport Android setup that the legacy downloader used
/// to perform before starting a real file transfer. This helper deliberately
/// owns no queue, task, retry, resume, or transport state.
Future<void> requestDownloadPermissionsV2() async {
  if (!Platform.isAndroid) return;

  final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
  if (!batteryStatus.isGranted) {
    await Permission.ignoreBatteryOptimizations.request();
  }

  final androidInfo = await DeviceInfoPlugin().androidInfo;
  if (androidInfo.version.sdkInt >= 30) {
    final storageStatus = await Permission.manageExternalStorage.status;
    if (!storageStatus.isGranted) {
      await Permission.manageExternalStorage.request();
    }
  } else {
    await Permission.storage.request();
  }
}

/// Resolves and persists AniSkip timestamps while the source is still online
/// so downloaded playback keeps intro/credits skipping when offline.
///
/// This is intentionally best-effort: skip metadata must never block a media
/// download or become another source of download ownership/state.
Future<void> cacheSkipSegmentsForDownloadV2(
  Ref ref,
  MultimediaItem item,
  Episode? episode,
) async {
  if (episode == null) return;
  final episodeUrl = episode.url.trim();
  if (episodeUrl.isEmpty) return;

  try {
    final settings = ref.read(settingsRepositoryProvider);
    final enabled =
        settings.getPlayerSetting<bool>(
          'player_skip_segments',
          defaultValue: true,
        ) ??
        true;
    if (!enabled) return;

    final cache = ref.read(skipSegmentCacheProvider);
    final keys = <String>[SkipSegmentCache.keyForEpisodeUrl(episodeUrl)];
    if (cache.readAny(keys).isNotEmpty) return;

    var malId = int.tryParse(
      (item.syncData?['malId'] ?? item.syncData?['mal_id'] ?? '').trim(),
    );
    malId ??= item.title.trim().isEmpty
        ? null
        : await ref.read(malIdResolverProvider).resolve(item.title);
    if (malId == null) return;

    final episodeNumber = episode.episode > 0 ? episode.episode : 1;
    final runtimeMinutes = int.tryParse(
      item.syncData?['awDuration']?.trim() ?? '',
    );
    final segments = await ref
        .read(aniSkipServiceProvider)
        .getSkipSegments(
          malId: malId,
          season: 1,
          episode: episodeNumber,
          duration: (runtimeMinutes != null && runtimeMinutes > 0)
              ? runtimeMinutes * 60
              : null,
        );
    if (segments.isEmpty) return;

    keys.add(SkipSegmentCache.keyForMal(malId, episodeNumber));
    await cache.write(keys, segments);
    if (kDebugMode) {
      debugPrint(
        '[DownloadV2] Cached ${segments.length} skip segments for '
        'episode $episodeNumber (mal $malId)',
      );
    }
  } catch (error) {
    if (kDebugMode) {
      debugPrint('[DownloadV2] Skip-segment preflight failed: $error');
    }
  }
}
