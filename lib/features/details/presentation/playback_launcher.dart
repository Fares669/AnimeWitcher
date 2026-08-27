import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/external_player_service.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/base_provider.dart';
import '../../settings/presentation/player_settings_provider.dart';
import 'package:collection/collection.dart';
import 'details_controller.dart';
import 'source_picker.dart';
import '../../../core/services/download_service.dart';
import '../../../shared/widgets/loading_dialog.dart';
import '../../../core/utils/app_utils.dart';
import '../../../core/utils/episode_label.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import '../../../core/services/notification_service.dart';
import '../../library/presentation/history_provider.dart';

part 'playback_launcher.g.dart';

@Riverpod(keepAlive: true)
PlaybackLauncher playbackLauncher(Ref ref) {
  return PlaybackLauncher(ref);
}

class PlaybackLauncher {
  final Ref _ref;

  PlaybackLauncher(this._ref);

  AnimeWitcherProvider? _resolveProvider(MultimediaItem item) {
    final manager = _ref.read(extensionManagerProvider.notifier);
    AnimeWitcherProvider? provider;
    if (item.provider != null) {
      try {
        final val = item.provider!;
        provider = manager.getAllProviders().firstWhere(
          (p) => p.packageName == val || p.name == val,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('PlaybackLauncher._resolveProvider: $e');
      }
    }
    return provider ?? _ref.read(activeProviderProvider);
  }

  Future<StreamResult?> _chooseSource(
    BuildContext context,
    AnimeWitcherProvider provider,
    String episodeDataUrl, {
    Episode? episode,
  }) async {
    bool isCanceled = false;
    bool dialogDismissed = false;
    unawaited(
      LoadingDialog.show(
        context,
        message: AppLocalizations.of(context)!.resolving,
        onCancel: () {
          isCanceled = true;
          dialogDismissed = true;
        },
      ),
    );

    try {
      final sources = await provider.loadStreamSources(episodeDataUrl);
      if (isCanceled || !context.mounted) return null;
      if (!dialogDismissed) {
        Navigator.of(context).pop();
        dialogDismissed = true;
      }
      if (sources.isEmpty) {
        _ref
            .read(notificationServiceProvider)
            .showError('لم يتم العثور على مصادر تشغيل.');
        return null;
      }
      return showStreamSourcePicker(
        context,
        sources,
        forDownload: false,
        episodeLabel: _episodeSourceLabel(episode),
      );
    } catch (e) {
      if (context.mounted && !isCanceled && !dialogDismissed) {
        Navigator.of(context).pop();
      }
      if (context.mounted) {
        _ref
            .read(notificationServiceProvider)
            .showError(
              AppLocalizations.of(context)!.usingInternalPlayerError(e.toString()),
            );
      }
      return null;
    }
  }

  /// Reuses the same source discovery + picker shown before initial playback.
  /// Downloaded episodes bypass the picker because they are already playable.
  Future<StreamResult?> chooseSourceForItem(
    BuildContext context,
    MultimediaItem item,
    String episodeDataUrl, {
    Episode? episode,
  }) async {
    final downloadService = _ref.read(downloadServiceProvider);
    final localFile = await downloadService.getDownloadedFile(
      item,
      episode: episode,
    );
    if (!context.mounted) return null;

    if (localFile != null) {
      return StreamResult(
        url: AppUtils.normalizeUrl(localFile.path),
        source: 'محلي',
      );
    }

    final provider = _resolveProvider(item);
    if (provider == null) {
      _ref
          .read(notificationServiceProvider)
          .showError('لم يتم العثور على مزود التشغيل.');
      return null;
    }

    return _chooseSource(context, provider, episodeDataUrl, episode: episode);
  }

  String? _episodeSourceLabel(Episode? episode) {
    if (episode == null) return null;
    final label = formatEpisodePrimaryLabel(
      episode: episode.episode,
      isArabic: true,
      isFinal: episode.isFinal,
      serverName: episode.serverName,
    );
    return label.isEmpty ? null : label;
  }

  Future<StreamResult?> _resolveSelectedSource(
    BuildContext context,
    AnimeWitcherProvider provider,
    StreamResult source,
  ) async {
    if (!source.requiresResolution) return source;

    bool isCanceled = false;
    bool dialogDismissed = false;
    unawaited(
      LoadingDialog.show(
        context,
        message: AppLocalizations.of(context)!.resolving,
        onCancel: () {
          isCanceled = true;
          dialogDismissed = true;
        },
      ),
    );
    try {
      final streams = await provider.loadStreams(source.url);
      if (isCanceled || !context.mounted) return null;
      if (!dialogDismissed) {
        Navigator.of(context).pop();
        dialogDismissed = true;
      }
      if (streams.isEmpty) {
        _ref
            .read(notificationServiceProvider)
            .showError('تعذر استخراج رابط صالح من هذا المصدر.');
        return null;
      }
      return streams.first;
    } catch (e) {
      if (context.mounted && !isCanceled && !dialogDismissed) {
        Navigator.of(context).pop();
      }
      if (context.mounted) {
        _ref
            .read(notificationServiceProvider)
            .showError(
              AppLocalizations.of(context)!.usingInternalPlayerError(e.toString()),
            );
      }
      return null;
    }
  }

  Future<void> _recordEpisodeOpened(
    MultimediaItem item,
    Episode? episode,
  ) async {
    if (episode == null) return;
    await _ref.read(watchHistoryProvider.notifier).recordOpened(
      item,
      lastEpisodeUrl: episode.url,
      season: episode.season,
      episode: episode.episode,
      episodeTitle: episodeTitleForStorage(
        episode: episode.episode,
        title: episode.name,
        isFinal: episode.isFinal,
        serverName: episode.serverName,
      ),
      episodeServerName: episode.serverName,
      episodePosterUrl: episode.posterUrl,
    );
  }

  Future<void> play(
    BuildContext context,
    String url, {
    required MultimediaItem baseItem,
    MultimediaItem? detailedItem,
    Episode? episode,
  }) async {
    final settings = await _ref.read(playerSettingsProvider.future);
    if (!context.mounted) return;

    final item = detailedItem ?? baseItem;
    final resolvedEpisode =
        episode ?? item.episodes?.firstWhereOrNull((e) => e.url == url);
    final resolvedEpisodeUrl = resolvedEpisode?.url.trim() ?? '';
    final canonicalProgressUrl =
        resolvedEpisodeUrl.isNotEmpty ? resolvedEpisodeUrl : url;
    String? downloadedPath;
    if (!AppUtils.isLocalFile(url)) {
      downloadedPath = (await _ref.read(downloadServiceProvider).getDownloadedFile(
        item,
        episode: resolvedEpisode,
      ))
          ?.path;
      if (!context.mounted) return;
    }

    final localOrEpisodeUrl = AppUtils.resolvePlayableUrl(
      requestedUrl: url,
      downloadedPath: downloadedPath,
    );

    // Downloaded files are already playable and do not need a source list.
    if (AppUtils.isLocalFile(localOrEpisodeUrl)) {
      await _recordEpisodeOpened(item, resolvedEpisode);
      if (settings.preferredPlayer != null) {
        final stream = StreamResult(url: localOrEpisodeUrl, source: 'محلي');
        await _launchStream(
          context,
          stream,
          item,
          localOrEpisodeUrl,
          settings.preferredPlayer!,
          episode: resolvedEpisode,
          progressUrl: canonicalProgressUrl,
        );
      } else {
        await PlayerRoute(
          $extra: PlayerRouteExtra(
            item: item,
            videoUrl: localOrEpisodeUrl,
            progressUrl: canonicalProgressUrl,
            episode: resolvedEpisode,
          ),
        ).push<void>(context);
      }
      return;
    }

    final provider = _resolveProvider(item);
    if (provider == null) {
      _ref
          .read(notificationServiceProvider)
          .showError('لم يتم العثور على مزود التشغيل.');
      return;
    }

    // Use the same quality/server picker for internal playback and downloads.
    // The selected source is carried into the player so it is not silently
    // replaced by saved-source or automatic quality preferences.
    final selected = await _chooseSource(
      context,
      provider,
      localOrEpisodeUrl,
      episode: resolvedEpisode,
    );
    if (selected == null || !context.mounted) return;

    if (settings.preferredPlayer == null) {
      await _recordEpisodeOpened(item, resolvedEpisode);
      if (!context.mounted) return;
      await PlayerRoute(
        $extra: PlayerRouteExtra(
          item: item,
          videoUrl: localOrEpisodeUrl,
          progressUrl: canonicalProgressUrl,
          episode: resolvedEpisode,
          selectedSource: selected,
        ),
      ).push<void>(context);
      return;
    }

    // External players still need a concrete resolved stream before launch.
    if (settings.preferredPlayer != null) {
      if (baseItem.url.isNotEmpty) {
        _ref
            .read(detailsControllerProvider(baseItem.url).notifier)
            .setLaunching(true);
      }
      try {
        final resolved = await _resolveSelectedSource(context, provider, selected);
        if (resolved == null || !context.mounted) return;
        await _recordEpisodeOpened(item, resolvedEpisode);
        await _launchStream(
          context,
          resolved,
          item,
          selected.url,
          settings.preferredPlayer!,
          episode: resolvedEpisode,
          progressUrl: canonicalProgressUrl,
        );
      } finally {
        if (baseItem.url.isNotEmpty) {
          _ref
              .read(detailsControllerProvider(baseItem.url).notifier)
              .setLaunching(false);
        }
      }
      return;
    }

  }

  Future<void> _launchStream(
    BuildContext context,
    StreamResult stream,
    MultimediaItem item,
    String fallbackVideoUrl,
    String playerId, {
    Episode? episode,
    String? progressUrl,
  }) async {
    final success = await ExternalPlayerService.instance.launch(
      stream.url,
      headers: stream.headers,
      playerId: playerId,
      title: item.title,
    );

    if (!success && context.mounted) {
      final playerName =
          ExternalPlayerService.instance.getPlayerById(playerId)?.displayName ??
          playerId;
      _ref
          .read(notificationServiceProvider)
          .showError(
            AppLocalizations.of(context)!.playerNotDetected(playerName),
          );
      unawaited(
        PlayerRoute(
          $extra: PlayerRouteExtra(
            item: item,
            videoUrl: fallbackVideoUrl,
            progressUrl: progressUrl,
            episode: episode,
          ),
        ).push<void>(context),
      );
    }
  }
}
