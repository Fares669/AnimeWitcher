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
import 'stream_source_prefetch.dart';
import 'downloaded_file_provider.dart';
import '../../../shared/widgets/loading_dialog.dart';
import '../../../core/utils/app_utils.dart';
import '../../../core/utils/episode_label.dart';
import '../../../core/utils/resume_episode.dart';
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

  bool _needsPlayerEpisodes(MultimediaItem item) {
    return item.contentType == MultimediaContentType.series ||
        item.contentType == MultimediaContentType.anime;
  }

  /// Continue-watching storage intentionally keeps a lightweight media item,
  /// so series/anime entries usually reach this launcher without `episodes`.
  /// Hydrate them before opening the internal player so its episode drawer,
  /// next/previous navigation and next-episode overlay all have the catalog.
  /// Failure is non-fatal: playback must still work when the catalog is
  /// temporarily unavailable (especially for an already downloaded episode).
  Future<MultimediaItem> _hydratePlayerEpisodes(
    MultimediaItem item, {
    AnimeWitcherProvider? provider,
  }) async {
    if ((item.episodes?.isNotEmpty ?? false) ||
        !_needsPlayerEpisodes(item) ||
        item.url.trim().isEmpty) {
      return item;
    }

    final resolvedProvider = provider ?? _resolveProvider(item);
    if (resolvedProvider == null) return item;

    try {
      final episodes = await resolvedProvider.getEpisodes(item.url);
      if (episodes.isEmpty) return item;
      return item.copyWith(
        episodes: episodes,
        provider: item.provider ?? resolvedProvider.packageName,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PlaybackLauncher._hydratePlayerEpisodes: $e');
      }
      return item;
    }
  }

  Episode? _canonicalEpisode(
    MultimediaItem item,
    Episode? episode,
    String progressUrl,
  ) {
    final episodes = item.episodes;
    if (episodes == null || episodes.isEmpty) return episode;

    return matchResumeEpisode(
          episodes,
          resumeEpisodeUrl: progressUrl,
          resumeEpisodeNumber: episode?.episode,
          resumeSeason: episode?.season,
        ) ??
        episode;
  }

  Future<StreamResult?> _chooseSource(
    BuildContext context,
    AnimeWitcherProvider provider,
    String episodeDataUrl, {
    Episode? episode,
    Future<List<StreamResult>> Function()? loadSources,
  }) async {
    if (!context.mounted) return null;
    // Hands over the warm fetch when the player started one as the credits
    // rolled, so the picker opens with its list already in hand.
    final future = loadSources != null
        ? loadSources()
        : _ref
              .read(streamSourcePrefetchProvider)
              .sources(provider, episodeDataUrl);
    return showStreamSourcePicker(
      context,
      const <StreamResult>[],
      sourcesFuture: future,
      forDownload: false,
      episodeLabel: episodePickerTitle(episode),
    );
  }

  /// Builds a catalog episode from continue-watching storage so the picker
  /// title and playback progress use the known anime + episode without
  /// waiting on the details page.
  Episode episodeFromContinueWatching(HistoryItem history) {
    return Episode(
      name: history.episodeTitle ?? '',
      url: history.lastEpisodeUrl ?? '',
      season: history.season ?? 0,
      episode: history.episode ?? 0,
      posterUrl: history.episodePosterUrl,
      serverName: history.episodeServerName ?? '',
    );
  }

  /// Opens Continue Watching directly on Home. A completed download is looked
  /// up by the canonical episode tracking URL first, so it bypasses the server
  /// picker. Online entries still use normal source selection, while both paths
  /// hydrate the episode catalog before the internal player is shown.
  Future<void> playFromContinueWatching(
    BuildContext context,
    HistoryItem history,
  ) async {
    final item = history.item;
    final savedUrl = history.lastEpisodeUrl?.trim() ?? '';
    final hintEpisode = episodeFromContinueWatching(history);

    if (savedUrl.isNotEmpty) {
      final localFile = await _ref
          .read(downloadedFilesProvider.notifier)
          .resolveFileForTrackingUrl(
            savedUrl,
            item: item,
            episode: hintEpisode,
          );
      if (!context.mounted) return;

      await play(
        context,
        localFile?.path ?? savedUrl,
        baseItem: item,
        episode: hintEpisode,
      );
      return;
    }

    final provider = _resolveProvider(item);
    if (provider == null) {
      _ref
          .read(notificationServiceProvider)
          .showError('لم يتم العثور على مزود التشغيل.');
      return;
    }

    Episode? resolvedEpisode =
        hintEpisode.episode > 0 || (hintEpisode.serverName.trim().isNotEmpty)
        ? hintEpisode
        : null;
    var resolvedUrl = '';
    var resolvedEpisodes = const <Episode>[];
    final selected = await _chooseSource(
      context,
      provider,
      item.url,
      episode: hintEpisode,
      loadSources: () async {
        resolvedEpisodes = await provider.getEpisodes(item.url);
        resolvedEpisode = matchResumeEpisode(
          resolvedEpisodes,
          resumeEpisodeUrl: history.lastEpisodeUrl,
          resumeEpisodeNumber: history.episode,
          resumeSeason: history.season,
        );
        if (resolvedEpisode == null &&
            resolvedEpisodes.isNotEmpty &&
            (history.episode == null || history.episode! <= 0)) {
          resolvedEpisode = resolvedEpisodes.first;
        }
        resolvedUrl = resolvedEpisode?.url.trim() ?? '';
        if (resolvedUrl.isEmpty) return const <StreamResult>[];
        return provider.loadStreamSources(resolvedUrl);
      },
    );
    if (selected == null || !context.mounted) return;
    if (resolvedUrl.isEmpty) return;

    final detailedItem = resolvedEpisodes.isEmpty
        ? null
        : item.copyWith(
            episodes: resolvedEpisodes,
            provider: item.provider ?? provider.packageName,
          );

    await play(
      context,
      resolvedUrl,
      baseItem: item,
      detailedItem: detailedItem,
      episode: resolvedEpisode,
      preselectedSource: selected,
    );
  }

  /// Reuses the same source discovery + picker shown before initial playback.
  /// Downloaded episodes bypass the picker because they are already playable.
  Future<StreamResult?> chooseSourceForItem(
    BuildContext context,
    MultimediaItem item,
    String episodeDataUrl, {
    Episode? episode,
  }) async {
    final localFile = await _ref
        .read(downloadedFilesProvider.notifier)
        .resolveFile(item, episode: episode);
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
              AppLocalizations.of(
                context,
              )!.usingInternalPlayerError(e.toString()),
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
    await _ref
        .read(watchHistoryProvider.notifier)
        .recordOpened(
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
    StreamResult? preselectedSource,
  }) async {
    final settings = await _ref.read(playerSettingsProvider.future);
    if (!context.mounted) return;

    final item = detailedItem ?? baseItem;
    // Start this immediately so episode metadata loads in parallel with local
    // file detection / source selection instead of adding another serial wait.
    final playerItemFuture = _hydratePlayerEpisodes(item);
    final resolvedEpisode =
        episode ?? item.episodes?.firstWhereOrNull((e) => e.url == url);
    final resolvedEpisodeUrl = resolvedEpisode?.url.trim() ?? '';
    final canonicalProgressUrl = resolvedEpisodeUrl.isNotEmpty
        ? resolvedEpisodeUrl
        : url;
    String? downloadedPath;
    if (!AppUtils.isLocalFile(url)) {
      downloadedPath =
          (await _ref
                  .read(downloadedFilesProvider.notifier)
                  .resolveFile(item, episode: resolvedEpisode))
              ?.path;
      if (!context.mounted) return;
    }

    final localOrEpisodeUrl = AppUtils.resolvePlayableUrl(
      requestedUrl: url,
      downloadedPath: downloadedPath,
    );

    // Downloaded files are already playable and do not need a source list.
    if (AppUtils.isLocalFile(localOrEpisodeUrl)) {
      final playerItem = await playerItemFuture;
      if (!context.mounted) return;
      final playerEpisode = _canonicalEpisode(
        playerItem,
        resolvedEpisode,
        canonicalProgressUrl,
      );

      await _recordEpisodeOpened(playerItem, playerEpisode);
      if (settings.preferredPlayer != null) {
        final stream = StreamResult(url: localOrEpisodeUrl, source: 'محلي');
        await _launchStream(
          context,
          stream,
          playerItem,
          localOrEpisodeUrl,
          settings.preferredPlayer!,
          episode: playerEpisode,
          progressUrl: canonicalProgressUrl,
        );
      } else {
        await PlayerRoute(
          $extra: PlayerRouteExtra(
            item: playerItem,
            videoUrl: localOrEpisodeUrl,
            progressUrl: canonicalProgressUrl,
            episode: playerEpisode,
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
    // Continue-watching on home may already have shown that picker.
    final selected =
        preselectedSource ??
        await _chooseSource(
          context,
          provider,
          localOrEpisodeUrl,
          episode: resolvedEpisode,
        );
    if (selected == null || !context.mounted) return;

    final playerItem = await playerItemFuture;
    if (!context.mounted) return;
    final playerEpisode = _canonicalEpisode(
      playerItem,
      resolvedEpisode,
      canonicalProgressUrl,
    );

    if (settings.preferredPlayer == null) {
      await _recordEpisodeOpened(playerItem, playerEpisode);
      if (!context.mounted) return;
      await PlayerRoute(
        $extra: PlayerRouteExtra(
          item: playerItem,
          videoUrl: localOrEpisodeUrl,
          progressUrl: canonicalProgressUrl,
          episode: playerEpisode,
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
        final resolved = await _resolveSelectedSource(
          context,
          provider,
          selected,
        );
        if (resolved == null || !context.mounted) return;
        await _recordEpisodeOpened(playerItem, playerEpisode);
        await _launchStream(
          context,
          resolved,
          playerItem,
          selected.url,
          settings.preferredPlayer!,
          episode: playerEpisode,
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
