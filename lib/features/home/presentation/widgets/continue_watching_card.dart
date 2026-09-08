import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/features/details/presentation/playback_launcher.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import '../../../../core/domain/entity/multimedia_item.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/utils/image_fallbacks.dart';
import 'package:animewitcher/core/utils/layout_constants.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../shared/widgets/cards_wrapper.dart';
import '../../../../shared/widgets/loading_dialog.dart';
import 'package:animewitcher/shared/widgets/taskbar_visibility.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/core/services/notification_service.dart';

import 'package:animewitcher/core/utils/localized_text.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/core/utils/episode_label.dart';

class ContinueWatchingCard extends ConsumerStatefulWidget {
  final HistoryItem historyItem;
  final double width;
  final bool isLarge;

  const ContinueWatchingCard({
    super.key,
    required this.historyItem,
    this.width = 280,
    this.isLarge = false,
  });

  @override
  ConsumerState<ContinueWatchingCard> createState() =>
      _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends ConsumerState<ContinueWatchingCard> {
  bool _isHovered = false;
  bool _isOpening = false;

  static String _normalizeMatchKey(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  static MultimediaItem? _pickBestLiveMatch(
    Iterable<MultimediaItem> candidates,
    MultimediaItem target,
  ) {
    final normalizedTarget = _normalizeMatchKey(target.title);
    if (normalizedTarget.isEmpty) return null;

    final exactTitleMatches = candidates.where(
      (candidate) =>
          candidate.contentType == MultimediaContentType.livestream &&
          _normalizeMatchKey(candidate.title) == normalizedTarget,
    );

    if (target.posterUrl.isNotEmpty) {
      final posterMatch = exactTitleMatches.firstWhereOrNull(
        (candidate) => candidate.posterUrl == target.posterUrl,
      );
      if (posterMatch != null) return posterMatch;
    }

    return exactTitleMatches.firstOrNull;
  }

  Future<MultimediaItem?> _resolveFreshLiveItem(
    WidgetRef ref,
    MultimediaItem item,
  ) async {
    final providerId = item.provider;
    if (providerId == null || providerId.isEmpty) return null;

    final manager = ref.read(extensionManagerProvider.notifier);
    final provider = manager.getAllProviders().firstWhereOrNull(
      (p) => p.packageName == providerId || p.name == providerId,
    );
    if (provider == null) return null;

    try {
      final results = await provider.search(item.title);
      final match = _pickBestLiveMatch(results, item);
      if (match != null) {
        return match.copyWith(provider: provider.packageName);
      }
    } catch (_) {}

    try {
      final homeSections = await provider.getHome();
      final flattened = homeSections.values.expand((items) => items);
      final match = _pickBestLiveMatch(flattened, item);
      if (match != null) {
        return match.copyWith(provider: provider.packageName);
      }
    } catch (_) {}

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.historyItem.item;
    final double progress = widget.historyItem.progress;

    final isLivestream = item.contentType == MultimediaContentType.livestream;
    final isSeries = item.contentType == MultimediaContentType.series;
    final isAnime = item.contentType == MultimediaContentType.anime;
    final hasEpisodes = isSeries || isAnime;

    final episodePosterUrl = AppImageFallbacks.optional(
      widget.historyItem.episodePosterUrl,
    );
    final animeBannerUrl = AppImageFallbacks.optional(item.bannerUrl);
    final animePosterUrl = AppImageFallbacks.poster(
      item.posterUrl,
      label: item.title,
    );
    final imageCandidates = <String>{
      if (hasEpisodes && episodePosterUrl != null) episodePosterUrl,
      if (animeBannerUrl != null) animeBannerUrl,
      if (animePosterUrl != null) animePosterUrl,
    }.toList(growable: false);
    Widget buildImageCandidate(int index) {
      if (index >= imageCandidates.length) {
        return const SizedBox.shrink();
      }
      return ArtworkDecode(
        paintedWidth: widget.width,
        builder: (BuildContext context, int? decodeWidth) => CachedNetworkImage(
          imageUrl: imageCandidates[index],
          fit: BoxFit.cover,
          memCacheWidth: decodeWidth,
          filterQuality: FilterQuality.medium,
          placeholder: (_, _) => const SizedBox.shrink(),
          errorWidget: (_, _, _) => buildImageCandidate(index + 1),
        ),
      );
    }

    final episodeNumber = widget.historyItem.episode;
    final episodeTitleRaw = widget.historyItem.episodeTitle ?? '';
    final episodeServerName = widget.historyItem.episodeServerName ?? '';
    final primaryLabel = continueWatchingPrimaryLabel(
      episode: episodeNumber,
      isArabic: true,
      episodeTitle: episodeTitleRaw,
      episodeServerName: episodeServerName,
    );
    final secondaryTitle = continueWatchingSecondaryTitle(
      episodeTitle: episodeTitleRaw,
      episodeServerName: episodeServerName,
      episode: episodeNumber,
    );
    final hasPrimaryLabel = primaryLabel.isNotEmpty;
    final hasSecondaryTitle = secondaryTitle.isNotEmpty;
    return CardsWrapper(
      onTap: () async {
        if (_isOpening) return;
        _isOpening = true;
        try {
          if (isLivestream) {
            bool dialogDismissed = false;
            bool canceled = false;
            unawaited(
              LoadingDialog.show(
                context,
                message: AppLocalizations.of(context)!.refreshingLiveStream,
                onCancel: () {
                  canceled = true;
                  dialogDismissed = true;
                },
              ),
            );
            final refreshedItem = await _resolveFreshLiveItem(ref, item);
            if (!context.mounted || canceled) return;

            if (!dialogDismissed) {
              Navigator.of(context, rootNavigator: true).pop();
              dialogDismissed = true;
            }

            final liveItem = refreshedItem ?? item;
            if (!context.mounted || canceled) return;

            unawaited(
              ref.read(continueWatchingProvider.notifier).remove(item.url),
            );
            await PlayerRoute(
              $extra: PlayerRouteExtra(item: liveItem, videoUrl: liveItem.url),
            ).push<void>(context);
            return;
          }

          await ref
              .read(playbackLauncherProvider)
              .playFromContinueWatching(context, widget.historyItem);
        } finally {
          _isOpening = false;
        }
      },
      onLongPress: () {
        final origin = context;
        showModalOverTaskbar<void>(
          context: origin,
          builder: (sheetContext) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    textDirection: TextDirection.ltr,
                    textAlign: TextAlign.start,
                    style: Theme.of(sheetContext).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: Text(AppLocalizations.of(sheetContext)!.viewDetails),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      if (!origin.mounted) return;
                      unawaited(
                        DetailsRoute(
                          $extra: DetailsRouteExtra(item: item),
                        ).push<void>(origin),
                      );
                    },
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.delete_outline,
                      color: Theme.of(sheetContext).colorScheme.error,
                    ),
                    title: Text(
                      AppLocalizations.of(sheetContext)!.removeFromHistory,
                      style: TextStyle(
                        color: Theme.of(sheetContext).colorScheme.error,
                      ),
                    ),
                    onTap: () {
                      ref
                          .read(continueWatchingProvider.notifier)
                          .remove(item.url);
                      Navigator.pop(sheetContext);
                      if (!origin.mounted) return;
                      ref
                          .read(notificationServiceProvider)
                          .showSuccess(
                            AppLocalizations.of(
                              origin,
                            )!.removedFromHistory(item.title),
                          );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.close),
                    title: Text(AppLocalizations.of(sheetContext)!.cancel),
                    onTap: () => Navigator.pop(sheetContext),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      borderRadius: BorderRadius.circular(LayoutConstants.radiusLg),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: SizedBox(
          width: widget.width,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(LayoutConstants.radiusLg),
            child: Stack(
              children: [
                // Banner background
                Positioned.fill(
                  child: Container(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    child: imageCandidates.isNotEmpty
                        ? buildImageCandidate(0)
                        : null,
                  ),
                ),

                // Dark overlay (full card) — 40% at rest, 60% on hover
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      color: Colors.black.withValues(
                        alpha: _isHovered ? 0.40 : 0.20,
                      ),
                    ),
                  ),
                ),

                // Bottom scrim gradient (from-black/80 to transparent)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 64,
                  child: IgnorePointer(
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Colors.black87, Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                ),

                // Duration badge (bottom-right)
                if (!isLivestream)
                  // Progress bar (bottom edge)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: SizedBox(
                      height: 4,
                      child: LinearProgressIndicator(
                        value: progress,
                        backgroundColor: Colors.transparent,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white,
                        ),
                      ),
                    ),
                  ),

                // Bottom info column
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      12,
                      24,
                      12,
                      hasSecondaryTitle ? 10 : 12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasEpisodes || isLivestream) ...[
                          Text(
                            item.title,
                            textDirection: TextDirection.ltr,
                            textAlign: TextAlign.start,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          SizedBox(height: hasSecondaryTitle ? 2 : 4),
                        ],
                        if (isLivestream)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red.withValues(alpha: 0.20),
                              borderRadius: BorderRadius.circular(
                                LayoutConstants.radiusSm,
                              ),
                            ),
                            child: Text(
                              appText(
                                context,
                                english: 'LIVE',
                                arabic: 'مباشر',
                              ),
                              style: const TextStyle(
                                color: Colors.red,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                          )
                        else if (hasPrimaryLabel || hasSecondaryTitle) ...[
                          if (hasPrimaryLabel)
                            Text(
                              primaryLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          if (hasSecondaryTitle) ...[
                            if (hasPrimaryLabel) const SizedBox(height: 2),
                            Text(
                              secondaryTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.62),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ] else
                          Text(
                            item.title,
                            textDirection: TextDirection.ltr,
                            textAlign: TextAlign.start,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
