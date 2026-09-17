import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/entity/multimedia_item.dart';
import '../../extensions/extension_manager.dart';
import '../../storage/settings_repository.dart';
import '../../storage/storage_service.dart';
import '../download_concurrency.dart';
import '../download_url_refresh.dart';
import 'background_downloader_gateway.dart';
import 'download_manager_v2.dart';
import 'download_integrity_verifier_v2.dart';
import 'download_source_resolver_v2.dart';
import 'download_v2_diagnostics.dart';
import 'download_v2_identity.dart';
import 'legacy_download_migration_v2.dart';
import 'logical_download_store_v2.dart';

/// Durable application-owned V2 metadata. This store intentionally remains
/// separate from both the legacy download job store and background_downloader's
/// transport database.
final logicalDownloadStoreV2Provider = Provider<LogicalDownloadStoreV2>((ref) {
  return HiveLogicalDownloadStoreV2();
});

/// The only transport authority used by Download Manager V2.
///
/// Before background_downloader is allowed to rehydrate or start transport,
/// the production gateway runs the one-way Policy-A presentation migration.
/// Migration itself never reads legacy executor/database state.
final backgroundDownloaderGatewayV2Provider =
    Provider<BackgroundDownloaderGateway>((ref) {
      return _MigrationFirstBackgroundDownloaderGateway(
        delegate: PackageBackgroundDownloaderGateway(),
        migrate: () => _migrateLegacyPresentationMetadata(ref),
      );
    });

/// Production source renewal adapter. It reuses provider/source selection
/// knowledge from the existing refresh helper, but never imports legacy
/// transport state, ranges, chunks, resume offsets, or writer ownership.
final downloadSourceResolverV2Provider = Provider<DownloadSourceResolverV2>((
  ref,
) {
  final extensions = ref.read(extensionManagerProvider.notifier);
  return _ProviderDownloadSourceResolverV2(
    DownloadUrlRefresher(providerForId: extensions.getProvider),
  );
});

/// Safe append-only V2 diagnostics. The user-facing download diagnostic switch
/// remains the authority for whether anything is written at all. The sink only
/// accepts the allowlisted V2 event DTO and writes inside the dedicated `log`
/// directory, so signed URLs/headers/provider payloads never reach this file.
final downloadDiagnosticsV2Provider = Provider<DownloadDiagnosticsV2>((ref) {
  final settings = ref.read(settingsRepositoryProvider);
  return FileDownloadDiagnosticsV2(
    enabled: settings.getDownloadDiagnosticLog,
    directoryProvider: () async {
      final documents = await getApplicationDocumentsDirectory();
      return Directory(p.join(documents.path, 'log'));
    },
  );
});

final downloadIntegrityVerifierV2Provider =
    Provider<DownloadIntegrityVerifierV2>(
      (_) => const DownloadIntegrityVerifierV2(),
    );

/// Keep-alive production coordinator. Reading this provider and calling
/// [DownloadManagerV2.initialize] is the single application startup hook for
/// V2; individual screens do not create their own managers or gateways.
final downloadManagerV2Provider = Provider<DownloadManagerV2>((ref) {
  final manager = DownloadManagerV2(
    store: ref.read(logicalDownloadStoreV2Provider),
    gateway: ref.read(backgroundDownloaderGatewayV2Provider),
    sourceResolver: ref.read(downloadSourceResolverV2Provider),
    integrityVerifier: ref.read(downloadIntegrityVerifierV2Provider),
    diagnostics: ref.read(downloadDiagnosticsV2Provider),
  );
  ref.onDispose(() {
    unawaited(manager.dispose());
  });
  return manager;
});

Future<void> _migrateLegacyPresentationMetadata(Ref ref) async {
  final storage = ref.read(storageServiceProvider);
  final store = ref.read(logicalDownloadStoreV2Provider);
  final refreshStore = ref.read(downloadUrlRefreshStoreProvider);
  final migration = LegacyDownloadMigrationV2(store: store);
  final metadataByTaskId = await storage.getAllDownloadMetadata();

  for (final entry in metadataByTaskId.entries) {
    try {
      final metadata = entry.value;
      final rawItem = metadata['item'];
      if (rawItem is! Map) continue;

      final destinationPath = (metadata['filePath'] as String?)?.trim() ?? '';
      if (destinationPath.isEmpty) continue;

      final item = MultimediaItem.fromJson(
        Map<String, dynamic>.from(rawItem),
      );
      final episode = metadata['episode'] is Map
          ? Episode.fromJson(
              Map<String, dynamic>.from(metadata['episode'] as Map),
            )
          : null;
      final trackingUrl = _legacyTrackingUrl(metadata, item, episode);
      if (trackingUrl.isEmpty) continue;

      // Metadata written by an already-existing V2 record is not legacy input.
      final storedLogicalId = (metadata['logicalId'] as String?)?.trim();
      if (storedLogicalId != null && storedLogicalId.isNotEmpty) {
        final existing = await store.get(DownloadLogicalId(storedLogicalId));
        if (existing != null) continue;
      }

      final expectedBytes = downloadMetadataExpectedBytes(metadata);
      final progress = downloadMetadataProgress(metadata);
      final finalFileValid = progress >= 1 &&
          await _legacyFinalFileIsValid(
            destinationPath,
            expectedBytes: expectedBytes,
          );

      // Current V1 downloads persist a stable provider/source refresh
      // descriptor. Incomplete rows without one cannot be safely restarted by
      // V2 without guessing a server, so they remain legacy presentation data.
      final refreshDescriptor = await refreshStore.get(trackingUrl);
      if (!finalFileValid && refreshDescriptor == null) continue;

      final animeId = _legacyAnimeId(item);
      if (animeId.isEmpty) continue;
      final variantKey = _legacySemanticVariantKey(
        item: item,
        episode: episode,
        quality: refreshDescriptor?.quality,
      );
      final logicalId = logicalDownloadIdFor(
        animeId: animeId,
        episodeKey: trackingUrl,
        variantKey: variantKey,
      );
      final timestamp = (metadata['timestamp'] as int?) ?? 0;
      final completedAtMillis = finalFileValid
          ? (timestamp > 0
                ? timestamp
                : DateTime.now().millisecondsSinceEpoch)
          : null;

      final migrated = await migration.migrate(
        LegacyDownloadPresentationV2(
          logicalId: logicalId,
          animeId: animeId,
          episodeKey: trackingUrl,
          variantKey: variantKey,
          destinationPath: destinationPath,
          sourceDescriptor: refreshDescriptor == null
              ? <String, Object?>{
                  'trackingUrl': trackingUrl,
                  'legacyCompleted': true,
                }
              : _applicationOwnedSourceDescriptor(refreshDescriptor),
          completedAtMillis: completedAtMillis,
          expectedBytes: expectedBytes > 0 ? expectedBytes : null,
        ),
      );

      // Presentation metadata may keep its legacy task id, but the canonical
      // logical id lets V2 UI/resolution join it to the migrated record.
      await storage.patchDownloadMetadata(
        entry.key,
        logicalId: migrated.logicalId.value,
      );
    } catch (_) {
      // One malformed/stale legacy presentation row must never prevent V2 or
      // background_downloader from initializing for healthy downloads.
    }
  }
}

String _legacyTrackingUrl(
  Map<String, dynamic> metadata,
  MultimediaItem item,
  Episode? episode,
) {
  final stored = (metadata['trackingUrl'] as String?)?.trim();
  if (stored != null && stored.isNotEmpty) return stored;
  final episodeUrl = episode?.url.trim();
  if (episodeUrl != null && episodeUrl.isNotEmpty) return episodeUrl;
  return item.url.trim();
}

String _legacyAnimeId(MultimediaItem item) {
  if (item.tmdbId != null) return item.tmdbId.toString();
  final imdbId = item.imdbId?.trim();
  if (imdbId != null && imdbId.isNotEmpty) return imdbId;
  return item.url.trim();
}

String _legacySemanticVariantKey({
  required MultimediaItem item,
  required Episode? episode,
  required String? quality,
}) {
  final audio = switch (episode?.dubStatus) {
    DubStatus.dubbed => 'dub',
    DubStatus.subbed => 'sub',
    _ => item.isDubbed ? 'dub' : 'default',
  };
  final normalizedQuality = quality?.trim().toLowerCase();
  if (normalizedQuality == null || normalizedQuality.isEmpty) return audio;
  return '$audio|$normalizedQuality';
}

Map<String, Object?> _applicationOwnedSourceDescriptor(
  DownloadUrlRefreshDescriptor descriptor,
) {
  return <String, Object?>{
    'trackingUrl': descriptor.trackingUrl,
    'providerId': descriptor.providerId,
    'source': descriptor.source,
    if (descriptor.quality?.trim().isNotEmpty ?? false)
      'quality': descriptor.quality,
    if (descriptor.refreshUrl?.trim().isNotEmpty ?? false)
      'refreshUrl': descriptor.refreshUrl,
    'updatedAtMillis': descriptor.updatedAtMillis,
  };
}

Future<bool> _legacyFinalFileIsValid(
  String path, {
  required int expectedBytes,
}) async {
  try {
    final file = File(path);
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length <= 0) return false;
    return expectedBytes <= 0 || length == expectedBytes;
  } catch (_) {
    return false;
  }
}

final class _MigrationFirstBackgroundDownloaderGateway
    implements BackgroundDownloaderGateway {
  _MigrationFirstBackgroundDownloaderGateway({
    required BackgroundDownloaderGateway delegate,
    required Future<void> Function() migrate,
  }) : _delegate = delegate,
       _migrate = migrate;

  final BackgroundDownloaderGateway _delegate;
  final Future<void> Function() _migrate;
  Future<void>? _initialization;

  @override
  Future<void> initialize() async {
    final existing = _initialization;
    if (existing != null) {
      await existing;
      return;
    }

    final current = _initializeOnce();
    _initialization = current;
    try {
      await current;
    } catch (_) {
      if (identical(_initialization, current)) _initialization = null;
      rethrow;
    }
  }

  Future<void> _initializeOnce() async {
    await _migrate();
    await _delegate.initialize();
  }

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    await initialize();
    return _delegate.start(spec);
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async {
    await initialize();
    return _delegate.attach(taskId);
  }

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async {
    await initialize();
    return _delegate.rehydrate();
  }

  @override
  Future<void> removeTracking(String taskId) async {
    await initialize();
    await _delegate.removeTracking(taskId);
  }
}

final class _ProviderDownloadSourceResolverV2
    implements DownloadSourceResolverV2 {
  const _ProviderDownloadSourceResolverV2(this._refresher);

  final DownloadUrlRefresher _refresher;

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    final refreshDescriptor = DownloadUrlRefreshDescriptor.fromJson(descriptor);
    if (refreshDescriptor == null) {
      throw StateError('Invalid V2 download source descriptor');
    }

    final refreshed = await _refresher.refresh(
      refreshDescriptor,
      // The V2 durable record intentionally contains no signed current URL.
      // DownloadUrlRefresher resolves from stable provider/source metadata.
      currentUrl: '',
    );
    if (refreshed == null || refreshed.url.trim().isEmpty) {
      throw StateError('Unable to resolve a fresh V2 download source');
    }

    return ResolvedDownloadSourceV2(
      url: refreshed.url.trim(),
      headers: Map<String, String>.from(refreshed.headers),
    );
  }
}
