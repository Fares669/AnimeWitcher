import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/domain/stream_source_preferences.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/network/dio_client_provider.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/download_parallel.dart';
import '../../../core/services/download_url_refresh.dart';
import '../../../core/services/download_v2/download_file_planner_v2.dart';
import '../../../core/services/download_v2/download_manager_v2.dart';
import '../../../core/services/download_v2/download_v2_identity.dart';
import '../../../core/services/download_v2/download_v2_models.dart';
import '../../../core/services/download_v2/download_v2_provider.dart';
import '../../../core/storage/settings_repository.dart';
import '../../../core/storage/storage_service.dart';
import '../../../shared/widgets/loading_dialog.dart';
import '../../../shared/widgets/custom_widgets.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../settings/presentation/general_settings_provider.dart';

import 'package:animewitcher/l10n/generated/app_localizations.dart';

import 'package:animewitcher/core/utils/localized_text.dart';
import 'package:animewitcher/core/services/notification_service.dart';

import 'download_start_preflight_v2.dart';
import 'source_picker.dart';
part 'download_launcher.g.dart';

@Riverpod(keepAlive: true)
DownloadLauncher downloadLauncher(Ref ref) {
  return DownloadLauncher(ref);
}

@visibleForTesting
String downloadFilenameV2({
  required String extension,
  required String? serverFilename,
  required MultimediaItem item,
  required Episode? episode,
  required String? quality,
  required bool forceEpisodeFilename,
}) {
  if (serverFilename != null && !forceEpisodeFilename) return serverFilename;
  if (episode != null &&
      (forceEpisodeFilename ||
          usesEpisodeDownloadFileName(
            episode: episode.episode,
            title: episode.name,
            serverName: episode.serverName,
          ))) {
    final episodeLabel = formatEpisodeDownloadFileName(
      episode: episode.episode,
      title: episode.name,
      quality: quality,
      isFinal: episode.isFinal,
      serverName: episode.serverName,
    );
    return '$episodeLabel$extension';
  }
  if (serverFilename != null) return serverFilename;
  final sanitizedTitle = sanitizeDownloadFileName(item.title);
  return '${sanitizedTitle.isEmpty ? 'video' : sanitizedTitle}$extension';
}

class DownloadLauncher {
  final Ref _ref;
  final Set<String> _launchingItems = <String>{};
  bool _batchInFlight = false;

  DownloadLauncher(this._ref);

  Future<void> launchBatch(
    BuildContext context,
    MultimediaItem item,
    List<Episode> selectedEpisodes,
  ) async {
    if (_batchInFlight || selectedEpisodes.isEmpty) return;
    _batchInFlight = true;
    final keys = <String>[];
    try {
      final records = await _ref.read(logicalDownloadStoreV2Provider).all();
      if (!context.mounted) return;
      final imdbId = item.imdbId?.trim();
      final mediaId =
          item.tmdbId?.toString() ??
          (imdbId?.isNotEmpty == true ? imdbId! : item.url.trim());
      final existingEpisodeKeys = <String>{
        for (final record in records)
          if (record.mediaKind == DownloadMediaKind.videoEpisode &&
              record.mediaId == mediaId &&
              (record.completedAtMillis != null ||
                  record.intent == DownloadUserIntent.active ||
                  record.intent == DownloadUserIntent.paused))
            record.unitKey.trim(),
      };
      final ordered = List<Episode>.of(selectedEpisodes)
        ..sort((a, b) {
          final season = a.season.compareTo(b.season);
          return season != 0 ? season : a.episode.compareTo(b.episode);
        });
      final episodes = <Episode>[];
      for (final episode in ordered) {
        final episodeKey = episode.url.trim();
        if (episodeKey.isEmpty || existingEpisodeKeys.contains(episodeKey)) {
          continue;
        }
        final key = '${item.provider ?? ''}|${item.url}|${episode.url}';
        if (_launchingItems.add(key)) {
          keys.add(key);
          episodes.add(episode);
        }
      }
      if (episodes.isEmpty) return;
      await _launchBatch(context, item, episodes);
    } finally {
      _launchingItems.removeAll(keys);
      _batchInFlight = false;
    }
  }

  Future<void> _launchBatch(
    BuildContext context,
    MultimediaItem item,
    List<Episode> episodes,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifications = _ref.read(notificationServiceProvider);
    final manager = _ref.read(extensionManagerProvider.notifier);
    AnimeWitcherProvider? provider;
    if (item.provider != null) {
      provider = manager.getAllProviders().firstWhereOrNull(
        (p) => p.packageName == item.provider || p.name == item.provider,
      );
    }
    provider ??= _ref.read(activeProviderProvider);
    if (provider == null) {
      notifications.showError('لا يوجد مزود تشغيل نشط');
      return;
    }

    final messenger = ScaffoldMessenger.maybeOf(context);
    final sourceProgress = ValueNotifier<int>(0);
    void showSourceProgress() {
      messenger?.showSnackBar(
        SnackBar(
          duration: const Duration(minutes: 2),
          content: ValueListenableBuilder<int>(
            valueListenable: sourceProgress,
            builder: (_, completed, _) =>
                Text('جاري فحص السيرفرات: $completed/${episodes.length}'),
          ),
        ),
      );
    }

    showSourceProgress();
    try {
      final allSources = List<List<StreamResult>?>.filled(
        episodes.length,
        null,
      );

      Future<List<int>> scan(List<int> indexes) async {
        final failed = <int>[];
        // Request each group together, without opening unlimited network calls.
        for (var start = 0; start < indexes.length; start += 4) {
          final chunk = indexes.skip(start).take(4).toList();
          final results = await Future.wait(
            chunk.map((index) async {
              try {
                final sources = await provider!.loadStreamSources(
                  episodes[index].url,
                );
                if (sources.where((s) => s.url.trim().isNotEmpty).isEmpty) {
                  throw StateError('No servers for episode');
                }
                allSources[index] = sources;
                sourceProgress.value = allSources
                    .whereType<List<StreamResult>>()
                    .length;
                return (index: index, error: null as Object?);
              } catch (error) {
                return (index: index, error: error as Object?);
              }
            }),
          );
          for (final result in results) {
            if (result.error != null) failed.add(result.index);
          }
        }
        return failed;
      }

      var pending = List<int>.generate(episodes.length, (index) => index);
      while (pending.isNotEmpty) {
        final failed = await scan(pending);
        if (failed.isEmpty) break;
        if (!context.mounted) return;
        messenger?.removeCurrentSnackBar();
        final retry = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('تعذر فحص بعض الحلقات'),
            content: Text(
              'تعذر جلب مصادر ${failed.length} من ${episodes.length} حلقة.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        );
        if (retry != true || !context.mounted) return;
        pending = failed;
        showSourceProgress();
      }
      if (!context.mounted) return;
      messenger?.hideCurrentSnackBar();
      final serverLists = <List<StreamResult>>[
        for (final sources in allSources) sources!,
      ];
      final common = commonBatchStreamSources(serverLists);
      if (common.isEmpty) {
        notifications.showError(
          'لا توجد جودة وسيرفر مشتركان بين كل الحلقات المحددة',
        );
        return;
      }

      final preferences = _ref.read(generalSettingsProvider);
      final orderedCommon = orderStreamSourcesByPreference(
        common,
        qualityPriority: preferences.streamQualityPriority,
        serverPriority: preferences.streamServerPriority,
      );
      final selected = await showStreamSourcePicker(
        context,
        orderedCommon,
        forDownload: true,
      );
      if (selected == null || !context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.confirmDownload),
          content: Text(
            'تنزيل ${episodes.length} حلقة بالترتيب التصاعدي\nالسيرفر: ${selected.source} — الجودة: ${selected.quality}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.downloadNow),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;

      var queued = 0;
      var failed = 0;
      final wantedSource = batchStreamSourceKey(selected);
      for (var i = 0; i < episodes.length; i++) {
        final episode = episodes[i];
        try {
          final candidates = serverLists[i]
              .where((source) => batchStreamSourceKey(source) == wantedSource)
              .toList();
          final resolved = await resolveBatchStreamSources(
            candidates,
            resolveCandidate: (candidate) =>
                provider!.loadStreams(candidate.url),
          );
          final prioritized = orderStreamSourcesByPreference(
            resolved
                .where(
                  (source) =>
                      wantedSource.$2 == 'متعدد' ||
                      streamQualityPreferenceKey(source.quality)
                              .toLowerCase() ==
                          wantedSource.$2,
                )
                .toList(),
            qualityPriority: preferences.streamQualityPriority,
            serverPriority: preferences.streamServerPriority,
          );
          if (prioritized.isEmpty) throw StateError('Missing stream URL');
          StreamResult? stream;
          DownloadSourceMetadataV2? metadata;
          for (final option in prioritized) {
            final probe = await probeDownloadSourceV2(
              _ref.read(dioClientProvider),
              option.url,
              headers: option.headers,
            ).timeout(const Duration(seconds: 15), onTimeout: () => null);
            if (probe?.size != null) {
              stream = option;
              metadata = probe;
              break;
            }
          }
          if (stream == null || metadata == null) {
            throw StateError('Unavailable source');
          }
          await _startDownload(
            stream,
            item,
            episode.url,
            metadata: metadata,
            providerId: provider.packageName,
            episode: episode,
            forceEpisodeFilename: true,
          );
          queued++;
        } catch (error) {
          failed++;
          if (kDebugMode) debugPrint('Batch download ${episode.url}: $error');
        }
      }
      if (failed == 0) {
        notifications.showSuccess('تمت إضافة $queued حلقة إلى التنزيلات');
      } else {
        notifications.showError('تمت إضافة $queued حلقة، وتعذر إضافة $failed');
      }
    } catch (error) {
      notifications.showError(_friendlyErrorMessage(l10n, error));
    } finally {
      messenger?.hideCurrentSnackBar();
      sourceProgress.dispose();
    }
  }

  Future<void> launch(
    BuildContext context,
    MultimediaItem item, {
    String? episodeUrl,
    Episode? episode,
  }) async {
    final resolveUrl = episodeUrl ?? episode?.url ?? item.url;
    if (resolveUrl.isEmpty) return;
    final key = '${item.provider ?? ''}|${item.url}|$resolveUrl';
    if (!_launchingItems.add(key)) return;
    try {
      await _launch(context, item, episodeUrl: episodeUrl, episode: episode);
    } finally {
      _launchingItems.remove(key);
    }
  }

  Future<void> _launch(
    BuildContext context,
    MultimediaItem item, {
    String? episodeUrl,
    Episode? episode,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final resolveUrl = episodeUrl ?? episode?.url ?? item.url;
    if (resolveUrl.isEmpty) return;
    final resolvedEpisode =
        episode ?? item.episodes?.firstWhereOrNull((e) => e.url == resolveUrl);

    final manager = _ref.read(extensionManagerProvider.notifier);
    AnimeWitcherProvider? provider;
    if (item.provider != null) {
      try {
        final val = item.provider!;
        provider = manager.getAllProviders().firstWhere(
          (p) => p.packageName == val || p.name == val,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('DownloadLauncher.launch: $e');
      }
    }
    provider ??= _ref.read(activeProviderProvider);
    if (provider == null) {
      _ref
          .read(notificationServiceProvider)
          .showError(l10n.errorPrefix('لا يوجد مزود تشغيل نشط'));
      return;
    }

    bool isCanceled = false;
    bool loadingDialogShown = false;

    try {
      final sourceFuture = provider.loadStreamSources(resolveUrl);
      final preferences = _ref.read(generalSettingsProvider);
      final StreamResult? selected;
      if (preferences.autoSelectStreamSource) {
        final sources = await sourceFuture;
        selected = await resolvePreferredStreamSource(
          sources,
          qualityPriority: preferences.streamQualityPriority,
          serverPriority: preferences.streamServerPriority,
          resolveCandidate: (StreamResult candidate) =>
              provider!.loadStreams(candidate.url),
        );
        if (selected == null) {
          throw Exception('لم يتم العثور على مصادر تشغيل.');
        }
      } else {
        selected = await showStreamSourcePicker(
          context,
          const <StreamResult>[],
          sourcesFuture: sourceFuture,
          forDownload: true,
          episodeLabel: episodePickerTitle(resolvedEpisode),
        );
      }
      if (selected == null || !context.mounted) return;
      StreamResult stream = selected;
      if (selected.requiresResolution) {
        isCanceled = false;
        loadingDialogShown = true;
        unawaited(
          LoadingDialog.show(
            context,
            message: l10n.loading,
            onCancel: () {
              isCanceled = true;
              loadingDialogShown = false;
            },
          ),
        );
        final resolved = await provider.loadStreams(selected.url);
        if (isCanceled || !context.mounted) return;
        if (loadingDialogShown) {
          Navigator.of(context, rootNavigator: true).pop();
          loadingDialogShown = false;
        }
        if (resolved.isEmpty) {
          throw Exception('تعذر استخراج رابط صالح من هذا المصدر.');
        }
        stream = resolved.first.refreshUrl?.trim().isNotEmpty == true
            ? resolved.first
            : resolved.first.copyWith(refreshUrl: selected.url);
      }

      await _verifyAndDownload(
        context,
        stream,
        item,
        resolveUrl,
        providerId: provider.packageName,
        episode: resolvedEpisode,
      );
    } catch (e) {
      if (!context.mounted) return;
      if (!isCanceled && loadingDialogShown) {
        Navigator.of(context, rootNavigator: true).pop();
        loadingDialogShown = false;
      }
      _ref
          .read(notificationServiceProvider)
          .showError(_friendlyErrorMessage(l10n, e));
    }
  }

  String _friendlyErrorMessage(AppLocalizations l10n, Object error) {
    var text = error.toString().trim();
    if (text.startsWith('Exception: ')) {
      text = text.substring('Exception: '.length).trim();
    }
    if (text.startsWith('Error: ')) {
      text = text.substring('Error: '.length).trim();
    }
    return text.isEmpty ? l10n.errorPrefix(error.toString()) : text;
  }

  Future<void> _verifyAndDownload(
    BuildContext context,
    StreamResult stream,
    MultimediaItem item,
    String resolveUrl, {
    required String providerId,
    Episode? episode,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final navContext = rootNavigatorKey.currentContext ?? context;

    bool isCanceled = false;
    unawaited(
      showDialog<void>(
        context: navContext,
        barrierDismissible: false,
        builder: (ctx) {
          return PopScope(
            canPop: false,
            child: AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppLoadingIndicator(),
                  const SizedBox(height: 16),
                  Text(l10n.verifyingSourceSize),
                ],
              ),
              actions: [
                CustomButton(
                  isPrimary: false,
                  onPressed: () {
                    isCanceled = true;
                    Navigator.of(ctx).pop();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(l10n.cancel),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    final metadata = await probeDownloadSourceV2(
      _ref.read(dioClientProvider),
      stream.url,
      headers: stream.headers,
    ).timeout(const Duration(seconds: 15), onTimeout: () => null);

    if (!navContext.mounted) return;
    if (!isCanceled) {
      Navigator.of(navContext, rootNavigator: true).pop();
    } else {
      return;
    }

    final finalContext = rootNavigatorKey.currentContext ?? navContext;

    if (metadata == null || metadata.size == null) {
      if (finalContext.mounted) {
        _showErrorDialog(
          finalContext,
          'This source doesn\'t support direct downloading or is currently unavailable. Please try another source.',
          stream,
          item,
          resolveUrl,
          episode: episode,
        );
      }
      return;
    }

    if (finalContext.mounted) {
      Future<void>? confirmationStart;
      await showDialog<void>(
        context: finalContext,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.confirmDownload),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.titleWithParam(item.title)),
              const SizedBox(height: 8),
              Text(l10n.sourceWithParam(stream.source)),
              const SizedBox(height: 8),
              Text(l10n.sizeWithParam(metadata.sizeString)),
              const SizedBox(height: 12),
              Row(
                textDirection: TextDirection.rtl,
                children: [
                  IconButton(
                    tooltip: appText(
                      ctx,
                      english: 'Copy link',
                      arabic: 'نسخ الرابط',
                    ),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: stream.url));
                      if (!ctx.mounted) return;
                      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
                        SnackBar(
                          content: Text(
                            appText(
                              ctx,
                              english: 'Link copied',
                              arabic: 'تم نسخ الرابط',
                            ),
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        stream.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(l10n.fileSaveLocationNotification),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel),
            ),
            ElevatedButton(
              onPressed: () {
                if (confirmationStart != null) return;
                confirmationStart = () async {
                  try {
                    await _startDownload(
                      stream,
                      item,
                      resolveUrl,
                      metadata: metadata,
                      providerId: providerId,
                      episode: episode,
                    );
                  } catch (error) {
                    if (!finalContext.mounted) return;
                    _ref
                        .read(notificationServiceProvider)
                        .showError(_friendlyErrorMessage(l10n, error));
                  }
                }();
                Navigator.pop(ctx);
              },
              child: Text(l10n.downloadNow),
            ),
          ],
        ),
      );
      await confirmationStart;
    }
  }

  /// Shared by single and batch downloads so file paths, V2 identities,
  /// refresh descriptors and metadata rollback stay identical.
  Future<void> _startDownload(
    StreamResult stream,
    MultimediaItem item,
    String resolveUrl, {
    required DownloadSourceMetadataV2 metadata,
    required String providerId,
    Episode? episode,
    bool forceEpisodeFilename = false,
  }) async {
    final episodeData =
        episode ?? item.episodes?.firstWhereOrNull((e) => e.url == resolveUrl);
    unawaited(cacheSkipSegmentsForDownloadV2(_ref, item, episodeData));
    final notificationPrefs = _ref
        .read(settingsRepositoryProvider)
        .getDownloadNotificationPrefs();
    await requestDownloadPermissionsV2(
      requestNotifications: !notificationPrefs.noneEnabled,
    );
    final extension = _getFileExtension(stream.url, metadata.mimeType);
    final filename = downloadFilenameV2(
      extension: extension,
      serverFilename: metadata.filename,
      item: item,
      episode: episodeData,
      quality: stream.quality,
      forceEpisodeFilename: forceEpisodeFilename,
    );

    final destinationPath = await downloadDestinationPathV2(
      item,
      episode: episodeData,
      filename: filename,
    );
    final imdbId = item.imdbId?.trim();
    final animeId =
        item.tmdbId?.toString() ??
        (imdbId?.isNotEmpty == true ? imdbId! : item.url.trim());
    final episodeKey = resolveUrl.trim();
    final audioVariant = switch (episodeData?.dubStatus) {
      DubStatus.dubbed => 'dub',
      DubStatus.subbed => 'sub',
      _ => item.isDubbed ? 'dub' : 'default',
    };
    final variantKey = downloadVariantKeyV2(
      audioVariant: audioVariant,
      quality: stream.quality,
    );
    final logicalId = logicalDownloadIdFor(
      animeId: animeId,
      episodeKey: episodeKey,
      variantKey: variantKey,
    );
    final descriptor = DownloadUrlRefreshDescriptor(
      trackingUrl: resolveUrl,
      providerId: providerId,
      source: stream.source,
      quality: stream.quality,
      refreshUrl: stream.refreshUrl,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    final preference = _ref
        .read(settingsRepositoryProvider)
        .getDownloadParallelParts();
    final isIOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    final selectedParallelChunks = selectV2DownloadParts(
      preference: preference,
      totalBytes: metadata.size ?? -1,
      metadataSupportsRanges: metadata.supportsRanges,
      isIOS: isIOS,
    );
    final parallelChunks = effectiveDownloadPartsForPlatform(
      selectedParts: selectedParallelChunks,
      isIOS: isIOS,
    );
    final absolutePath = await absoluteDownloadDestinationPathV2(
      destinationPath,
    );
    final storage = _ref.read(storageServiceProvider);
    final hasExistingMetadata =
        await storage.getDownloadMetadata(logicalId.value) != null;
    if (!hasExistingMetadata) {
      await storage.saveDownloadMetadata(
        logicalId.value,
        item,
        episode: episodeData,
        trackingUrl: resolveUrl,
        filePath: absolutePath,
        logicalId: logicalId.value,
      );
    }

    final downloadManager = _ref.read(downloadManagerV2Provider);
    try {
      await downloadManager.start(
        DownloadStartRequestV2(
          logicalId: logicalId,
          mediaId: animeId,
          unitKey: episodeKey,
          variantKey: variantKey,
          destinationPath: destinationPath,
          sourceDescriptor: descriptor.toJson(),
          expectedBytes: metadata.size,
          allowPause: true,
          retries: 2,
          parallelChunks: parallelChunks,
        ),
      );
      if (hasExistingMetadata) {
        await storage.saveDownloadMetadata(
          logicalId.value,
          item,
          episode: episodeData,
          trackingUrl: resolveUrl,
          filePath: absolutePath,
          logicalId: logicalId.value,
        );
      }
    } catch (startError, startStackTrace) {
      if (!hasExistingMetadata) {
        await storage.removeDownloadMetadata(logicalId.value);
      }
      Error.throwWithStackTrace(startError, startStackTrace);
    }
  }

  void _showErrorDialog(
    BuildContext context,
    String message,
    StreamResult stream,
    MultimediaItem item,
    String resolveUrl, {
    Episode? episode,
  }) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.downloadUnavailable),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              launch(context, item, episodeUrl: resolveUrl, episode: episode);
            },
            child: Text(l10n.selectAnotherSource),
          ),
        ],
      ),
    );
  }

  String _getFileExtension(String url, String? mimeType) {
    if (mimeType != null) {
      if (mimeType.contains('video/mp4')) return '.mp4';
      if (mimeType.contains('video/x-matroska')) return '.mkv';
      if (mimeType.contains('video/webm')) return '.webm';
    }

    final uri = Uri.tryParse(url);
    if (uri != null) {
      final path = uri.path.toLowerCase();
      if (path.endsWith('.mp4')) return '.mp4';
      if (path.endsWith('.mkv')) return '.mkv';
      if (path.endsWith('.webm')) return '.webm';
      if (path.endsWith('.avi')) return '.avi';
    }

    return '.mp4';
  }
}
