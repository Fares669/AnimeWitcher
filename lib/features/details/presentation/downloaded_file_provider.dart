import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/services/download_v2/download_file_planner_v2.dart';
import '../../../core/services/download_v2/download_v2_provider.dart';

part 'downloaded_file_provider.g.dart';

/// Tracks completed files from V2 logical records only.
@Riverpod(keepAlive: true)
class DownloadedFiles extends _$DownloadedFiles {
  @override
  Map<String, File?> build() => const <String, File?>{};

  Future<File?> resolveFile(
    MultimediaItem item, {
    Episode? episode,
  }) {
    return _resolveFileForKey(episode?.url ?? item.url);
  }

  Future<File?> resolveFileForTrackingUrl(
    String trackingUrl, {
    required MultimediaItem item,
    Episode? episode,
  }) {
    final key = trackingUrl.trim();
    return _resolveFileForKey(
      key.isNotEmpty ? key : (episode?.url ?? item.url),
    );
  }

  Future<File?> _resolveFileForKey(String key) async {
    final manager = ref.read(downloadManagerV2Provider);
    final records = await manager.records.first;

    File? resolved;
    final matching = records
        .where(
          (record) =>
              record.completedAtMillis != null && record.episodeKey == key,
        )
        .toList(growable: false)
      ..sort((a, b) => b.updatedAtMillis.compareTo(a.updatedAtMillis));

    for (final record in matching) {
      // completedAtMillis is a logical claim, not sufficient byte evidence.
      // Re-check the final artifact through the same V2 integrity authority
      // before returning it to playback.
      if (!await manager.hasCompletedDownload(record.logicalId)) continue;
      final path = await absoluteDownloadDestinationPathV2(
        record.destinationPath,
      );
      final file = File(path);
      if (await file.exists()) {
        resolved = file;
        break;
      }
    }


    return resolved;
  }

  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {
    final key = episode?.url ?? item.url;
    final resolved = await resolveFile(item, episode: episode);
    state = {...state, key: resolved};
  }

  void removeFile(String key) {
    state = {...state, key: null};
  }
}
