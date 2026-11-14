import 'dart:io';
import 'dart:convert';
import 'dart:async';

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
  final _pendingChecks = <String, _FileCheck>{};
  final _latestChecks = <String, _FileCheck>{};
  int _generation = 0;

  @override
  Map<String, File?> build() {
    ref.watch(accountDataRevisionProvider);
    _generation++;
    ref.onDispose(() => _generation++);
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
    List<LogicalDownloadRecordV2>? sharedRecords,
  }) async {
    // Native completed files only require local metadata and integrity data.
    // Avoid initializing the transport coordinator just to play an offline
    // native episode. Rift needs its account restored before file selection.
    final manager = isAnimeRiftDownloadProviderV2(providerId)
        ? ref.read(downloadManagerV2Provider)
        : null;
    if (manager != null) await manager.ensureRiftAccountReady();
    final accountAtStart = AnimeRiftLocalAccountScope.accountHash;
    final selected = logicalId?.trim();
    if (selected != null && selected.isEmpty) return null;
    final unitKey = _downloadUnitKeyForProvider(key, providerId);
    // Completed playback depends only on durable local metadata and bytes,
    // never on transport startup or remote download recovery.
    final store = ref.read(logicalDownloadStoreV2Provider);
    final verifier = ref.read(downloadIntegrityVerifierV2Provider);
    final records = sharedRecords ?? await store.all();

    File? resolved;
    final matching =
        records
            .where(
              (record) =>
                  record.mediaKind == DownloadMediaKind.videoEpisode &&
                  (manager?.canAccessSourceDescriptor(
                        record.sourceDescriptor,
                      ) ??
                      downloadBelongsToCurrentRiftAccountV2(
                        record.sourceDescriptor,
                      )) &&
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

  Future<void> checkFile(MultimediaItem item, {Episode? episode}) {
    final key = downloadedFileKey(item, episode: episode);
    final previous = _pendingChecks[key];
    if (previous != null &&
        previous.generation == _generation &&
        previous.account == AnimeRiftLocalAccountScope.accountHash) {
      return previous.done.future;
    }
    previous?.done.complete();
    final check = _FileCheck(item, episode, _generation);
    _pendingChecks[key] = check;
    _latestChecks[key] = check;
    if (_pendingChecks.length == 1) {
      scheduleMicrotask(() => unawaited(_flushChecks()));
    }
    // Keep queued card metadata bounded, even for a caller mounting many rows.
    if (_pendingChecks.length >= 128) unawaited(_flushChecks());
    return check.done.future;
  }

  Future<void> _flushChecks() async {
    if (_pendingChecks.isEmpty) return;
    final batch = Map.of(_pendingChecks);
    _pendingChecks.clear();
    final resolved = <String, File?>{};
    try {
      if (!ref.mounted) return;
      // Share only this batch's read. The next batch sees completions, imports
      // and deletions immediately; playback resolution always reads afresh.
      final records = await ref.read(logicalDownloadStoreV2Provider).all();
      await Future.wait(
        batch.entries.map((entry) async {
          final check = entry.value;
          try {
            final file = await _resolveFileForKey(
              check.episode?.url ?? check.item.url,
              providerId: check.item.provider,
              sharedRecords: records,
            );
            resolved[entry.key] = file;
          } catch (error, stack) {
            check.done.completeError(error, stack);
          }
        }),
      );
      if (!ref.mounted) return;
      final changed = resolved.entries.where((entry) {
        final check = batch[entry.key]!;
        return identical(_latestChecks[entry.key], check) &&
            check.generation == _generation &&
            check.account == AnimeRiftLocalAccountScope.accountHash &&
            state[entry.key]?.path != entry.value?.path;
      });
      if (changed.isNotEmpty) state = {...state, ...Map.fromEntries(changed)};
    } catch (error, stack) {
      for (final check in batch.values) {
        if (!check.done.isCompleted) check.done.completeError(error, stack);
      }
    } finally {
      for (final entry in batch.entries) {
        final check = entry.value;
        if (identical(_latestChecks[entry.key], check)) {
          _latestChecks.remove(entry.key);
        }
        if (!check.done.isCompleted) check.done.complete();
      }
    }
  }

  void removeFile(String key) {
    _generation++;
    if (state[key] != null) state = {...state, key: null};
  }
}

class _FileCheck {
  _FileCheck(this.item, this.episode, this.generation)
    : account = AnimeRiftLocalAccountScope.accountHash;

  final MultimediaItem item;
  final Episode? episode;
  final int generation;
  final String? account;
  final done = Completer<void>();
}

String _downloadUnitKeyForProvider(String value, String? providerId) {
  final trimmed = value.trim();
  if (!isAnimeRiftDownloadProviderV2(providerId)) return trimmed;
  return animeRiftDownloadTrackingIdentityV2(trimmed) ?? trimmed;
}
