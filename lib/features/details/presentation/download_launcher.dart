import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/network/dio_client_provider.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/download_parallel.dart';
import '../../../core/services/download_url_refresh.dart';
import '../../../core/services/download_v2/download_file_planner_v2.dart';
import '../../../core/services/download_v2/download_manager_v2.dart';
import '../../../core/services/download_v2/download_v2_identity.dart';
import '../../../core/services/download_v2/download_v2_provider.dart';
import '../../../core/storage/settings_repository.dart';
import '../../../core/storage/storage_service.dart';
import '../../../shared/widgets/loading_dialog.dart';
import '../../../shared/widgets/custom_widgets.dart';
import '../../../shared/widgets/loading_indicator.dart';

import 'package:animewitcher/l10n/generated/app_localizations.dart';

import 'package:animewitcher/core/utils/localized_text.dart';
import 'package:animewitcher/core/services/notification_service.dart';

import 'source_picker.dart';
part 'download_launcher.g.dart';

@Riverpod(keepAlive: true)
DownloadLauncher downloadLauncher(Ref ref) {
  return DownloadLauncher(ref);
}

class DownloadLauncher {
  final Ref _ref;

  DownloadLauncher(this._ref);

  Future<void> launch(
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
    bool dialogDismissed = false;

    try {
      final selected = await showStreamSourcePicker(
        context,
        const <StreamResult>[],
        sourcesFuture: provider.loadStreamSources(resolveUrl),
        forDownload: true,
        episodeLabel: episodePickerTitle(resolvedEpisode),
      );
      if (selected == null || !context.mounted) return;
      dialogDismissed = true;

      StreamResult stream = selected;
      if (selected.requiresResolution) {
        isCanceled = false;
        dialogDismissed = false;
        unawaited(
          LoadingDialog.show(
            context,
            message: l10n.loading,
            onCancel: () {
              isCanceled = true;
              dialogDismissed = true;
            },
          ),
        );
        final resolved = await provider.loadStreams(selected.url);
        if (isCanceled || !context.mounted) return;
        if (!dialogDismissed) {
          Navigator.of(context).pop();
          dialogDismissed = true;
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
      if (!isCanceled && !dialogDismissed) {
        Navigator.of(context).pop();
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
      unawaited(
        showDialog<void>(
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
                        await Clipboard.setData(
                          ClipboardData(text: stream.url),
                        );
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
                onPressed: () async {
                  Navigator.pop(ctx);
                  try {
                    final episodeData =
                        episode ??
                        item.episodes?.firstWhereOrNull(
                          (e) => e.url == resolveUrl,
                        );
                    final extension = _getFileExtension(
                      stream.url,
                      metadata.mimeType,
                    );
                    final String filename;
                    if (episodeData != null &&
                        usesEpisodeDownloadFileName(
                          episode: episodeData.episode,
                          title: episodeData.name,
                          serverName: episodeData.serverName,
                        )) {
                      final episodeLabel = sanitizeDownloadFileName(
                        formatEpisodeFileName(
                          episode: episodeData.episode,
                          title: episodeData.name,
                          quality: stream.quality,
                          isFinal: episodeData.isFinal,
                          serverName: episodeData.serverName,
                        ),
                      );
                      filename = '$episodeLabel$extension';
                    } else {
                      final sanitizedTitle = sanitizeDownloadFileName(
                        item.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim(),
                      );
                      filename = '$sanitizedTitle$extension';
                    }

                    final destinationPath = await downloadDestinationPathV2(
                      item,
                      episode: episodeData,
                      filename: filename,
                    );
                    final imdbId = item.imdbId?.trim();
                    final animeId =
                        item.tmdbId?.toString() ??
                        (imdbId?.isNotEmpty == true
                            ? imdbId!
                            : item.url.trim());
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
                    final parallelChunks = selectAdaptiveDownloadParts(
                      preference: preference,
                      totalBytes: metadata.size ?? -1,
                      supportsRanges: metadata.supportsRanges,
                    );
                    final absolutePath =
                        await absoluteDownloadDestinationPathV2(destinationPath);
                    final storage = _ref.read(storageServiceProvider);
                    await storage.saveDownloadMetadata(
                      logicalId.value,
                      item,
                      episode: episodeData,
                      trackingUrl: resolveUrl,
                      filePath: absolutePath,
                      logicalId: logicalId.value,
                    );

                    final downloadManager = _ref.read(downloadManagerV2Provider);
                    try {
                      await downloadManager.start(
                        DownloadStartRequestV2(
                          logicalId: logicalId,
                          animeId: animeId,
                          episodeKey: episodeKey,
                          variantKey: variantKey,
                          destinationPath: destinationPath,
                          sourceDescriptor: descriptor.toJson(),
                          expectedBytes: metadata.size,
                          allowPause: true,
                          retries: 2,
                          parallelChunks: parallelChunks,
                        ),
                      );
                    } catch (startError, startStackTrace) {
                      await storage.removeDownloadMetadata(logicalId.value);
                      Error.throwWithStackTrace(startError, startStackTrace);
                    }
                  } catch (error) {
                    if (!finalContext.mounted) return;
                    _ref
                        .read(notificationServiceProvider)
                        .showError(_friendlyErrorMessage(l10n, error));
                  }
                },
                child: Text(l10n.downloadNow),
              ),
            ],
          ),
        ),
      );
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
              launch(
                context,
                item,
                episodeUrl: resolveUrl,
                episode: episode,
              );
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
