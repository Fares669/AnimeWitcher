import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/services/download_service.dart';
import '../../../core/router/app_router.dart';
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
    unawaited(
      LoadingDialog.show(
        context,
        message: l10n.resolving,
        onCancel: () {
          isCanceled = true;
          dialogDismissed = true;
        },
      ),
    );

    try {
      // Fetch only AnimeWitcher's source records here. Extraction happens
      // after the user chooses PD/MF2/ST/etc.
      final sources = await provider.loadStreamSources(resolveUrl);
      if (isCanceled || !context.mounted) return;
      if (!dialogDismissed) {
        Navigator.of(context).pop();
        dialogDismissed = true;
      }
      if (sources.isEmpty) {
        throw Exception('لم يتم العثور على مصادر تنزيل لهذا العنصر.');
      }

      final selected = await showStreamSourcePicker(
        context,
        sources,
        forDownload: true,
        episodeLabel: resolvedEpisode == null
            ? null
            : formatEpisodePrimaryLabel(
                episode: resolvedEpisode.episode,
                isArabic: true,
                isFinal: resolvedEpisode.isFinal,
                serverName: resolvedEpisode.serverName,
              ),
      );
      if (selected == null || !context.mounted) return;

      StreamResult stream = selected;
      if (selected.requiresResolution) {
        isCanceled = false;
        dialogDismissed = false;
        unawaited(
          LoadingDialog.show(
            context,
            message: l10n.resolving,
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
        stream = resolved.first;
      }

      await _verifyAndDownload(
        context,
        stream,
        item,
        resolveUrl,
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
    Episode? episode,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final downloadService = _ref.read(downloadServiceProvider);

    // 1. Show verification dialog
    // Use root navigator context if current context is unmounted
    final navContext = rootNavigatorKey.currentContext ?? context;

    bool isCanceled = false;
    unawaited(
      showDialog<void>(
        context: navContext,
        barrierDismissible: false, // Block UI interaction
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

    final metadata = await downloadService
        .getMetadata(stream.url, headers: stream.headers)
        .timeout(const Duration(seconds: 15), onTimeout: () => null);

    if (!navContext.mounted) return;
    if (!isCanceled) {
      Navigator.of(navContext, rootNavigator: true).pop();
    } else {
      return; // Canceled, don't proceed
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

    // 2. Show Confirmation Dialog
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
                const SizedBox(height: 16),
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

                  // Prefer the episode from the card (has isFinal/serverName).
                  // Fall back to item.episodes when launching without one.
                  final episodeData = episode ??
                      item.episodes?.firstWhereOrNull(
                        (e) => e.url == resolveUrl,
                      );
                  final saveDir = await downloadService.getDownloadPath(
                    item,
                    episode: episodeData,
                  );

                  final extension = _getFileExtension(
                    stream.url,
                    metadata.mimeType,
                  );
                  String filename;
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
                    filename = "$sanitizedTitle$extension";
                  }

                  if (kDebugMode) {
                    debugPrint(
                      '[DownloadLauncher] Final Path: $saveDir/$filename',
                    );
                  }

                  final started = await downloadService.startDownload(
                    url: stream.url,
                    filename: filename,
                    directory: saveDir,
                    item: item,
                    episode: episodeData,
                    trackingUrl: resolveUrl,
                    headers: stream.headers,
                    totalBytes: metadata.size ?? -1,
                  );

                  if (!started && finalContext.mounted) {
                    _ref.read(notificationServiceProvider).showError(
                      appText(
                        finalContext,
                        english:
                            'Failed to start download. Check storage permissions.',
                        arabic: 'فشل بدء التنزيل. تحقق من أذونات التخزين.',
                      ),
                    );
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
              ); // Go back to source picker
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

    return '.mp4'; // Default
  }
}
