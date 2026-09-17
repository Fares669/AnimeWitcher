import 'dart:io';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/services/download_v2/download_file_planner_v2.dart';
import '../../../core/services/download_v2/download_v2_provider.dart';
import '../../../core/storage/storage_service.dart';

part 'downloaded_file_provider.g.dart';

/// Tracks completed files without consulting the legacy transport service.
///
/// V2 logical records are authoritative. Presentation metadata is retained as
/// a compatibility fallback for already-completed legacy downloads until the
/// physical-device gate allows Task 14 to remove legacy storage completely.
@Riverpod(keepAlive: true)
class DownloadedFiles extends _$DownloadedFiles {
  @override
  Map<String, File?> build() => const <String, File?>{};

  Future<File?> resolveFile(
    MultimediaItem item, {
    Episode? episode,
  }) async {
    final key = episode?.url ?? item.url;
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
      final path = await absoluteDownloadDestinationPathV2(
        record.destinationPath,
      );
      final file = File(path);
      if (await file.exists()) {
        resolved = file;
        break;
      }
    }

    // Policy-A compatibility: completed legacy files remain playable even
    // before their presentation metadata is rewritten as a V2 logical record.
    // This reads only app-owned metadata and never adopts V1 transport state.
    if (resolved == null) {
      final metadata = await ref
          .read(storageServiceProvider)
          .getAllDownloadMetadata();
      final candidates = metadata.values.where((entry) {
        return entry['trackingUrl'] == key && entry['filePath'] is String;
      });
      for (final entry in candidates) {
        final path = (entry['filePath'] as String).trim();
        if (path.isEmpty) continue;
        final file = File(path);
        if (await file.exists()) {
          resolved = file;
          break;
        }
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
