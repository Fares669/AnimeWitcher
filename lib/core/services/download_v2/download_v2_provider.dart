import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../extensions/extension_manager.dart';
import '../../storage/settings_repository.dart';
import '../download_url_refresh.dart';
import 'background_downloader_gateway.dart';
import 'download_manager_v2.dart';
import 'download_source_resolver_v2.dart';
import 'download_v2_diagnostics.dart';
import 'logical_download_store_v2.dart';

/// Durable application-owned V2 metadata. This store intentionally remains
/// separate from both the legacy download job store and background_downloader's
/// transport database.
final logicalDownloadStoreV2Provider = Provider<LogicalDownloadStoreV2>((ref) {
  return HiveLogicalDownloadStoreV2();
});

/// The only transport authority used by Download Manager V2.
final backgroundDownloaderGatewayV2Provider =
    Provider<BackgroundDownloaderGateway>((ref) {
      return PackageBackgroundDownloaderGateway();
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

/// Keep-alive production coordinator. Reading this provider and calling
/// [DownloadManagerV2.initialize] is the single application startup hook for
/// V2; individual screens do not create their own managers or gateways.
final downloadManagerV2Provider = Provider<DownloadManagerV2>((ref) {
  final manager = DownloadManagerV2(
    store: ref.read(logicalDownloadStoreV2Provider),
    gateway: ref.read(backgroundDownloaderGatewayV2Provider),
    sourceResolver: ref.read(downloadSourceResolverV2Provider),
    diagnostics: ref.read(downloadDiagnosticsV2Provider),
  );
  ref.onDispose(() {
    unawaited(manager.dispose());
  });
  return manager;
});

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
