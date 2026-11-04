import 'dart:io';
import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/account/account_providers.dart';
import '../../../core/storage/anime_rift_account_scope.dart';
import '../../../core/services/download_v2/anime_rift_download_metadata_v2.dart';
import '../../../core/services/download_v2/download_file_planner_v2.dart';
import '../../../core/services/download_v2/download_v2_identity.dart';
import '../../../core/services/download_v2/download_v2_models.dart';
import '../../../core/services/download_v2/download_v2_provider.dart';

part 'downloaded_file_provider.g.dart';

String downloadedFileKey(MultimediaItem item, {Episode? episode}) {
  final url = episode?.url ?? item.url;
  final scope = downloadProviderScopeV2(item.provider);
  final account = isAnimeRiftDownloadProviderV2(item.provider)
      ? AnimeRiftLocalAccountScope.accountHash
      : null;
  if (account != null) return jsonEncode([scope, account, url]);
  return scope == null ? url : jsonEncode([scope, url]);
}

/// Tracks completed files from V2 logical records only.
@Riverpod(keepAlive: true)
class DownloadedFiles extends _$DownloadedFiles {
  @override
  Map<String, File?> build() {
    ref.watch(accountDataRevisionProvider);
    return const <String, File?>{};
  }

  Future<File?> resolveFile(
    MultimediaItem item, {
    Episode? episode,
    String? logicalId,
  }) {
    return _resolveFileForKey(
      episode?.url ?? item.url,
      logicalId: logicalId,
      providerId: item.provider,
    );
  }

  Future<File?> resolveFileForTrackingUrl(
    String trackingUrl, {
    required MultimediaItem item,
    Episode? episode,
  }) {
    final key = trackingUrl.trim();
    return _resolveFileForKey(
      key.isNotEmpty ? key : (episode?.url ?? item.url),
      providerId: item.provider,
    );
  }

  Future<File?> _resolveFileForKey(
    String key, {
    String? logicalId,
    String? providerId,
  }) async {
    final manager = ref.read(downloadManagerV2Provider);
    if (isAnimeRiftDownloadProviderV2(providerId)) {
      await manager.ensureRiftAccountReady();
    }
    final accountAtStart = AnimeRiftLocalAccountScope.accountHash;
    final selected = logicalId?.trim();
    if (selected != null && selected.isEmpty) return null;
    final unitKey = _downloadUnitKeyForProvider(key, providerId);
    // Completed playback depends only on durable local metadata and bytes,
    // never on transport startup or remote download recovery.
    final store = ref.read(logicalDownloadStoreV2Provider);
    final verifier = ref.read(downloadIntegrityVerifierV2Provider);
    final records = await store.all();

    File? resolved;
    final matching =
        records
            .where(
              (record) =>
                  record.mediaKind == DownloadMediaKind.videoEpisode &&
                  manager.canAccessSourceDescriptor(record.sourceDescriptor) &&
                  record.completedAtMillis != null &&
                  _downloadUnitKeyForProvider(
                        record.unitKey,
                        record.sourceDescriptor['providerId']?.toString(),
                      ) ==
                      unitKey &&
                  downloadProviderScopeV2(
                        record.sourceDescriptor['providerId']?.toString(),
                      ) ==
                      downloadProviderScopeV2(providerId) &&
                  (selected != null
                      ? record.logicalId.value == selected
                      : true),
            )
            .toList(growable: false)
          ..sort((a, b) => b.updatedAtMillis.compareTo(a.updatedAtMillis));

    for (final record in matching) {
      if (accountAtStart != AnimeRiftLocalAccountScope.accountHash) return null;
      // completedAtMillis is a logical claim, not sufficient byte evidence.
      // Re-check the final artifact through the same V2 integrity authority
      // before returning it to playback.
      final path = await absoluteDownloadDestinationPathV2(
        record.destinationPath,
      );
      final file = File(path);
      if ((await verifier.verify(
        file,
        expectedBytes: record.expectedBytes,
      )).isValid) {
        if (accountAtStart != AnimeRiftLocalAccountScope.accountHash)
          return null;
        resolved = file;
        break;
      }
    }

    return resolved;
  }

  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {
    final key = downloadedFileKey(item, episode: episode);
    final resolved = await resolveFile(item, episode: episode);
    state = {...state, key: resolved};
  }

  void removeFile(String key) {
    state = {...state, key: null};
  }
}

String _downloadUnitKeyForProvider(String value, String? providerId) {
  final trimmed = value.trim();
  if (!isAnimeRiftDownloadProviderV2(providerId)) return trimmed;
  return animeRiftDownloadTrackingIdentityV2(trimmed) ?? trimmed;
}
