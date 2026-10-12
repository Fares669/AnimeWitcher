import 'dart:io';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/services/download_v2/download_artwork_store_v2.dart';

/// Legacy task-owned location, retained for exact-record offline migration.
Future<File?> downloadedEpisodeArtworkFile(String taskId) =>
    downloadArtworkStoreV2.legacyFileFor(taskId);

Future<File?> existingDownloadedEpisodeArtwork(String taskId) =>
    downloadArtworkStoreV2.existingLegacy(taskId);

Future<File?> ensureDownloadedEpisodeArtwork({
  required String taskId,
  required Episode? episode,
  String? logicalId,
  bool allowMetadataBackfill = true,
}) async {
  final logical = logicalId?.trim() ?? '';
  if (!allowMetadataBackfill) {
    // Reading an already-owned copy needs no live metadata. Unknown task-key
    // metadata never imports a legacy file into a logical variant's ownership.
    return logical.isEmpty ? await existingDownloadedEpisodeArtwork(taskId)
        : await downloadArtworkStoreV2.existing(
      logical, DownloadArtworkKindV2.episode,
    );
  }
  if (logical.isEmpty) {
    // Old callers may have lost remote metadata after an offline restart.
    final legacy = await existingDownloadedEpisodeArtwork(taskId);
    if (legacy != null) return legacy;
  }
  return downloadArtworkStoreV2.ensure(
    logicalId: logical.isEmpty ? taskId : logical,
    kind: DownloadArtworkKindV2.episode,
    url: episode?.posterUrl,
    legacyTaskId: taskId,
  );
}

Future<File?> existingDownloadedPosterArtwork(String logicalId) =>
    downloadArtworkStoreV2.existing(logicalId, DownloadArtworkKindV2.poster);

Future<File?> ensureDownloadedPosterArtwork({
  required String logicalId,
  required String? posterUrl,
}) => downloadArtworkStoreV2.ensure(
  logicalId: logicalId, kind: DownloadArtworkKindV2.poster, url: posterUrl,
);

Future<void> retainDownloadedArtwork({
  required String logicalId,
  required String taskId,
  required MultimediaItem item,
  required Episode? episode,
}) async {
  await Future.wait([
    ensureDownloadedEpisodeArtwork(taskId: taskId, logicalId: logicalId, episode: episode),
    ensureDownloadedPosterArtwork(logicalId: logicalId, posterUrl: item.posterUrl),
  ]);
}

Future<void> deleteDownloadedEpisodeArtwork(String taskId) =>
    deleteDownloadArtworkV2(taskId, legacyTaskId: taskId);
