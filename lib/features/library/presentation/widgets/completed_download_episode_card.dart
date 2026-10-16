import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:animewitcher/core/utils/image_fallbacks.dart';
import 'package:animewitcher/core/utils/layout_constants.dart';
import 'package:animewitcher/features/details/presentation/widgets/episode_action_chip.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart'
    show watchHistoryProvider;
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/thumbnail_error_placeholder.dart';

import '../download_episode_artwork.dart';
import '../downloads_provider.dart';

/// Episode-row presentation for the Completed downloads tab.
///
/// This deliberately follows the details-page [EpisodeCard] watch-state
/// presentation: the same watched darkening, progress line, and
/// watched/watching/last-watched badge rules. The only action difference is a
/// single delete button centered where download + comments normally live.
class CompletedDownloadEpisodeCard extends ConsumerStatefulWidget {
  const CompletedDownloadEpisodeCard({
    super.key,
    required this.item,
    required this.onPlay,
    required this.onDelete,
  });

  final DownloadItem item;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  @override
  ConsumerState<CompletedDownloadEpisodeCard> createState() =>
      _CompletedDownloadEpisodeCardState();
}

class _CompletedDownloadEpisodeCardState
    extends ConsumerState<CompletedDownloadEpisodeCard> {
  late Future<File?> _artwork;

  @override
  void initState() {
    super.initState();
    _artwork = _loadArtwork();
  }

  @override
  void didUpdateWidget(covariant CompletedDownloadEpisodeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.logicalId != widget.item.logicalId ||
        oldWidget.item.artworkMetadataVerified !=
            widget.item.artworkMetadataVerified ||
        oldWidget.item.episode?.posterUrl != widget.item.episode?.posterUrl ||
        oldWidget.item.item.bannerUrl != widget.item.item.bannerUrl ||
        oldWidget.item.item.posterUrl != widget.item.item.posterUrl) {
      _artwork = _loadArtwork();
    }
  }

  Future<File?> _loadArtwork() => ensureDownloadedEpisodeArtwork(
    taskId: widget.item.id,
    logicalId: widget.item.logicalId,
    episode: widget.item.episode,
    item: widget.item.item,
    allowMetadataBackfill: widget.item.artworkMetadataVerified,
  );

  _EpisodeWatchPresentation _watchPresentation(
    BuildContext context,
    HistoryItem? historyItem,
  ) {
    final episode = widget.item.episode;
    if (episode == null) return const _EpisodeWatchPresentation();

    HistoryRepository? historyRepo;
    EpisodeWatchRepository? episodeWatchRepo;

    // DownloadsTab widget tests intentionally mount only the downloads
    // provider. Production always supplies these repositories at app scope;
    // keeping the reads guarded means the card can still render a neutral
    // state in isolated previews/tests instead of coupling them to app setup.
    try {
      historyRepo = ref.watch(historyRepositoryProvider);
    } catch (_) {}
    try {
      ref.watch(episodeWatchRevisionProvider);
    } catch (_) {}
    try {
      ref.watch(accountDataRevisionProvider);
    } catch (_) {}
    try {
      episodeWatchRepo = ref.watch(episodeWatchRepositoryProvider);
    } catch (_) {}

    if (historyRepo == null) return const _EpisodeWatchPresentation();

    final epPos = historyRepo.getEpisodePosition(
      episode.url,
      mainUrl: widget.item.item.url,
      season: episode.season,
      episode: episode.episode,
    );
    final epDur = historyRepo.getEpisodeDuration(
      episode.url,
      mainUrl: widget.item.item.url,
      season: episode.season,
      episode: episode.episode,
    );
    final progress = epDur > 0 ? (epPos / epDur).clamp(0.0, 1.0) : 0.0;

    final explicitWatchState = episodeWatchRepo?.getExplicitState(
      widget.item.item.url,
      episode,
    );
    final isWatched =
        episodeWatchRepo?.isWatched(widget.item.item.url, episode) ??
        (epDur > 0 && progress >= 0.90);
    final displayedProgress = isWatched ? 1.0 : progress;

    final l10n = AppLocalizations.of(context)!;
    String? statusBadge;
    if (isWatched) {
      statusBadge = l10n.watched.toUpperCase();
    } else if (progress > 0.02) {
      statusBadge = l10n.watching.toUpperCase();
    }

    if (historyItem != null &&
        statusBadge == null &&
        explicitWatchState != false) {
      final hSeason = historyItem.season ?? 1;
      final hEpisode = historyItem.episode ?? 1;
      if (episode.season == hSeason && episode.episode == hEpisode) {
        statusBadge = l10n.lastWatched.toUpperCase();
      }
    }

    return _EpisodeWatchPresentation(
      isWatched: isWatched,
      progress: displayedProgress,
      statusBadge: statusBadge,
    );
  }

  HistoryItem? _historyItemForSeries() {
    List<HistoryItem> history = const <HistoryItem>[];
    try {
      history = ref.watch(watchHistoryProvider);
    } catch (_) {
      return null;
    }
    for (final item in history) {
      if (item.item.url == widget.item.item.url) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final episode = widget.item.episode;
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final episodeTitle = episode == null ? '' : realEpisodeTitle(episode.name);
    final episodeNumberLabel = episode == null
        ? widget.item.item.title
        : formatEpisodePrimaryLabel(
            episode: episode.episode,
            isArabic: isArabic,
            isFinal: episode.isFinal,
            serverName: episode.serverName,
          );
    final description = episode?.description?.trim() ?? '';
    final watchState = _watchPresentation(context, _historyItemForSeries());
    final normalCardColor = theme.colorScheme.surfaceContainerLow;
    final watchedCardColor = Color.alphaBlend(
      Colors.black.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.30 : 0.14,
      ),
      normalCardColor,
    );
    final episodeNumberStyle = theme.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.bold,
      color: watchState.isWatched
          ? theme.colorScheme.onSurface.withValues(alpha: 0.65)
          : theme.colorScheme.onSurface,
    );

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: InkWell(
        onTap: widget.onPlay,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: watchState.isWatched ? watchedCardColor : normalCardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.dividerColor.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.1 : 0.5,
              ),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.all(LayoutConstants.spacingSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildThumbnail(
                    context,
                    watchState.progress,
                    watchState.statusBadge,
                    isWatched: watchState.isWatched,
                  ),
                  const SizedBox(width: LayoutConstants.spacingMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          textDirection: isArabic
                              ? TextDirection.rtl
                              : TextDirection.ltr,
                          children: [
                            if (episodeNumberLabel.isNotEmpty)
                              Text(
                                episodeNumberLabel,
                                style: episodeNumberStyle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if (episode?.isFiller == true) ...[
                              const SizedBox(width: 8),
                              _buildFillerBadge(isArabic),
                            ],
                          ],
                        ),
                        if (episodeTitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            episodeTitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w500,
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(
                                    alpha: watchState.isWatched ? 0.55 : 0.72,
                                  ),
                              height: 1.25,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: LayoutConstants.spacingXs),
                  // EpisodeCard normally stacks two 34px actions with an 8px
                  // gap (34 + 8 + 34 = 76). Center the one delete action in
                  // that exact vertical footprint so it sits between the old
                  // download and comments positions.
                  SizedBox(
                    width: 34,
                    height: 76,
                    child: Center(
                      child: EpisodeActionChip(
                        tooltip: isArabic ? 'حذف الحلقة' : 'Delete episode',
                        icon: Icons.delete_outline_rounded,
                        color: theme.colorScheme.error,
                        onPressed: widget.onDelete,
                      ),
                    ),
                  ),
                ],
              ),
              if (description.isNotEmpty) ...[
                const SizedBox(height: LayoutConstants.spacingSm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.8,
                      ),
                      height: 1.4,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFillerBadge(bool isArabic) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFD32F2F),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isArabic ? 'فلر' : 'FILLER',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildThumbnail(
    BuildContext context,
    double progress,
    String? statusBadge, {
    required bool isWatched,
  }) {
    final episode = widget.item.episode;
    final episodePosterUrl = AppImageFallbacks.optional(episode?.posterUrl);
    final fallbackUrl =
        episodePosterUrl ??
        AppImageFallbacks.episode(
          bannerUrl: widget.item.item.bannerUrl,
          posterUrl: widget.item.item.posterUrl,
        );
    final placeholderColor = Theme.of(context)
        .colorScheme
        .surfaceContainerHighest;

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 140,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: FutureBuilder<File?>(
                future: _artwork,
                builder: (context, snapshot) {
                  final local = snapshot.data;
                  if (local != null) {
                    return ArtworkDecode(
                      paintedWidth: 140,
                      builder: (context, decodeWidth) => Image.file(
                        local,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        cacheWidth: decodeWidth,
                        filterQuality: FilterQuality.medium,
                        errorBuilder: (_, _, _) => _networkThumbnail(
                          fallbackUrl,
                          episodePosterUrl,
                          placeholderColor,
                        ),
                      ),
                    );
                  }
                  return _networkThumbnail(
                    fallbackUrl,
                    episodePosterUrl,
                    placeholderColor,
                  );
                },
              ),
            ),
          ),
        ),
        if (isWatched)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.black.withValues(alpha: 0.28),
                ),
              ),
            ),
          ),
        if (progress > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: Colors.black26,
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        if (statusBadge != null)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                statusBadge,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _networkThumbnail(
    String? imageUrl,
    String? episodePosterUrl,
    Color placeholderColor,
  ) {
    if (imageUrl == null || imageUrl.isEmpty) {
      return const ThumbnailErrorPlaceholder();
    }
    return ArtworkDecode(
      paintedWidth: 140,
      builder: (context, decodeWidth) => CachedNetworkImage(
        imageUrl: imageUrl,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        memCacheWidth: decodeWidth,
        filterQuality: FilterQuality.medium,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        useOldImageOnUrlChange: true,
        placeholder: (_, _) => ColoredBox(color: placeholderColor),
        errorWidget: (_, _, _) => episodePosterUrl != null
            ? ColoredBox(color: placeholderColor)
            : const ThumbnailErrorPlaceholder(),
      ),
    );
  }
}

class _EpisodeWatchPresentation {
  const _EpisodeWatchPresentation({
    this.isWatched = false,
    this.progress = 0,
    this.statusBadge,
  });

  final bool isWatched;
  final double progress;
  final String? statusBadge;
}
