import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/features/comments/presentation/animewitcher_comments_screen.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/episode_watch_repository.dart';
import 'package:animewitcher/core/services/download_service.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:animewitcher/core/utils/image_fallbacks.dart';
import 'package:animewitcher/core/utils/layout_constants.dart';
import 'package:animewitcher/core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../library/presentation/history_provider.dart';
import '../details_controller.dart';
import '../download_launcher.dart';
import '../downloaded_file_provider.dart';
import 'download_progress_dialog.dart';
import 'download_management_dialog.dart';
import '../../../../l10n/generated/app_localizations.dart';

/// `{series} - {episode}` for download dialogs, keeping the name of numberless
/// rows (specials, OVAs, مترجم/مدبلج) instead of an empty trailing dash.
String _downloadDialogTitle(MultimediaItem parentItem, Episode episode) {
  final label = formatEpisodeLabel(
    episode: episode.episode,
    isArabic: true,
    title: episode.name,
    isFinal: episode.isFinal,
    serverName: episode.serverName,
  );
  return label.isEmpty ? parentItem.title : '${parentItem.title} - $label';
}

class EpisodeCard extends HookConsumerWidget {
  final Episode episode;
  final MultimediaItem parentItem;
  final double? width;

  const EpisodeCard({
    super.key,
    required this.episode,
    required this.parentItem,
    this.width,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final episodeTitle = realEpisodeTitle(episode.name);
    final episodeNumberLabel = formatEpisodePrimaryLabel(
      episode: episode.episode,
      isArabic: isArabic,
      isFinal: episode.isFinal,
      serverName: episode.serverName,
    );
    final hasPrimaryLabel = episodeNumberLabel.isNotEmpty;
    final hasServerName = episodeTitle.isNotEmpty;
    final historyRepo = ref.watch(historyRepositoryProvider);
    final historyItem = ref.watch(
      watchHistoryProvider.select(
        (list) => list.whereType<HistoryItem>().firstWhereOrNull(
          (h) => h.item.url == parentItem.url,
        ),
      ),
    );

    final epPos = historyRepo.getEpisodePosition(
      episode.url,
      mainUrl: parentItem.url,
      season: episode.season,
      episode: episode.episode,
    );
    final epDur = historyRepo.getEpisodeDuration(
      episode.url,
      mainUrl: parentItem.url,
      season: episode.season,
      episode: episode.episode,
    );

    ref.watch(episodeWatchRevisionProvider);
    ref.watch(accountDataRevisionProvider);
    final episodeWatchRepo = ref.watch(episodeWatchRepositoryProvider);

    final double progress = epDur > 0 ? (epPos / epDur).clamp(0.0, 1.0) : 0.0;
    final explicitWatchState = episodeWatchRepo.getExplicitState(
      parentItem.url,
      episode,
    );
    final isWatched = episodeWatchRepo.isWatched(parentItem.url, episode);
    final displayedProgress = isWatched ? 1.0 : progress;

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
      final eSeason = episode.season;
      final eEpisode = episode.episode;

      if (eSeason == hSeason && eEpisode == hEpisode) {
        statusBadge = l10n.lastWatched.toUpperCase();
      }
    }

    final activeDownloads = ref.watch(activeDownloadsProvider);
    final isDownloading = activeDownloads.contains(episode.url);
    final detailsState = ref.watch(detailsControllerProvider(parentItem.url));
    final details = detailsState.item;
    final selectionKey = episodeSelectionKey(episode);
    final isSelectionMode = detailsState.selectedEpisodeKeys.isNotEmpty;
    final isSelected = detailsState.selectedEpisodeKeys.contains(selectionKey);

    final progressMap = ref.watch(downloadProgressProvider);
    final downloadProgressData = progressMap[episode.url];
    final downloadProgress = downloadProgressData?.progress ?? 0.0;

    final downloadedFile = ref.watch(downloadedFilesProvider)[episode.url];

    // Check for downloaded file on load
    useEffect(() {
      if (!isDownloading) {
        Future.microtask(() {
          if (ref.context.mounted) {
            ref
                .read(downloadedFilesProvider.notifier)
                .checkFile(parentItem, episode: episode);
          }
        });
      }
      return null;
    }, [episode.url, isDownloading]);

    final isFocused = useState(false);
    final downloadFocusNode = useFocusNode(debugLabel: 'ep_download');
    final bodyFocusNode = useFocusNode(debugLabel: 'ep_body');
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final normalCardColor = theme.colorScheme.surfaceContainerLow;
    final watchedCardColor = Color.alphaBlend(
      Colors.black.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.30 : 0.14,
      ),
      normalCardColor,
    );
    final episodeNumberStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.bold,
      color: isWatched
          ? theme.colorScheme.onSurface.withValues(alpha: 0.65)
          : theme.colorScheme.onSurface,
    );

    void triggerDownload() {
      if (downloadedFile != null) {
        DownloadManagementDialog.show(
          context,
          details ?? parentItem,
          downloadedFile,
          episode: episode,
        );
      } else if (isDownloading) {
        DownloadProgressDialog.show(
          context,
          _downloadDialogTitle(parentItem, episode),
          episode.url,
        );
      } else {
        ref
            .read(downloadLauncherProvider)
            .launch(
              context,
              parentItem,
              episodeUrl: episode.url,
              episode: episode,
            );
      }
    }

    void updateSelection() {
      HapticFeedback.selectionClick();

      ref
          .read(detailsControllerProvider(parentItem.url).notifier)
          .toggleEpisodeSelection(episode);
    }

    void handleEpisodeTap() {
      final selectionActive = ref
          .read(detailsControllerProvider(parentItem.url))
          .selectedEpisodeKeys
          .isNotEmpty;

      if (selectionActive) {
        updateSelection();
        return;
      }

      ref
          .read(detailsControllerProvider(parentItem.url).notifier)
          .handlePlayPress(context, parentItem, specificEpisode: episode);
    }

    final selectKeyDown = useRef(false);
    final longPressTriggered = useRef(false);

    return Focus(
      // Passive observer — let the inner InkWell be the real focus target so
      // OK plays and Right can traverse into the download icon (a descendant).
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        isFocused.value = f;
        if (!f) {
          selectKeyDown.value = false;
          longPressTriggered.value = false;
        }
        if (f) {
          // Center the focused episode in the viewport when reachable.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final ctx = FocusManager.instance.primaryFocus?.context;
            final ro = ctx?.findRenderObject();
            if (ctx != null && ctx.mounted && ro != null) {
              Scrollable.maybeOf(ctx)?.position.ensureVisible(
                ro,
                alignment: 0.5,
                duration: const Duration(milliseconds: 380),
                curve: Curves.fastOutSlowIn,
              );
            }
          });
        }
      },
      child: Focus(
        focusNode: bodyFocusNode,
        onKeyEvent: (node, event) {
          // Menu key → trigger download immediately.
          final isMenu =
              event.logicalKey == LogicalKeyboardKey.contextMenu ||
              event.logicalKey == LogicalKeyboardKey.f10;
          if (event is KeyDownEvent && isMenu) {
            triggerDownload();
            return KeyEventResult.handled;
          }

          // Select / Enter / Space → long-press detection via KeyRepeatEvent.
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            if (event is KeyDownEvent) {
              selectKeyDown.value = true;
              longPressTriggered.value = false;
              return KeyEventResult.handled;
            } else if (event is KeyRepeatEvent) {
              if (selectKeyDown.value && !longPressTriggered.value) {
                longPressTriggered.value = true;
                updateSelection();
              }
              return KeyEventResult.handled;
            } else if (event is KeyUpEvent) {
              if (selectKeyDown.value && !longPressTriggered.value) {
                // Short press plays normally, or toggles when selecting.
                handleEpisodeTap();
              }
              selectKeyDown.value = false;
              longPressTriggered.value = false;
              return KeyEventResult.handled;
            }
          }

          return KeyEventResult.ignored;
        },
        child: InkWell(
          onTap: handleEpisodeTap,
          onLongPress: updateSelection,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: width,
            decoration: BoxDecoration(
              color: isSelected
                  ? primary.withValues(alpha: 0.24)
                  : isFocused.value
                  ? primary.withValues(alpha: 0.18)
                  : isWatched
                  ? watchedCardColor
                  : normalCardColor,
              borderRadius: BorderRadius.circular(12.0),
              border: Border.all(
                color: isSelected || isFocused.value
                    ? primary
                    : Theme.of(context).dividerColor.withValues(
                        alpha: Theme.of(context).brightness == Brightness.dark
                            ? 0.1
                            : 0.5,
                      ),
                width: isSelected || isFocused.value ? 2 : 1,
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
                      displayedProgress,
                      statusBadge,
                      isWatched: isWatched,
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
                              if (hasPrimaryLabel)
                                Text(
                                  episodeNumberLabel,
                                  style: episodeNumberStyle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              if (episode.isFiller) ...[
                                const SizedBox(width: 8),
                                _buildFillerBadge(isArabic),
                              ],
                            ],
                          ),
                          if (hasServerName) ...[
                            const SizedBox(height: 2),
                            Text(
                              episodeTitle,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w500,
                                    color: theme.colorScheme.onSurfaceVariant
                                        .withValues(
                                          alpha: isWatched ? 0.55 : 0.72,
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
                    // Download icon — uses an explicit FocusNode so the parent
                    // onKeyEvent can force focus here from the body. Left from
                    // the icon returns focus to the body via this widget's own
                    // onKeyEvent.
                    if (isSelectionMode)
                      Icon(
                        isSelected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: isSelected
                            ? primary
                            : theme.colorScheme.onSurfaceVariant,
                        size: 30,
                      )
                    else
                      _buildActionButtons(
                        context,
                        ref,
                        downloadedFile,
                        isDownloading,
                        downloadProgress,
                        downloadProgressData,
                        details,
                        downloadFocusNode,
                        bodyFocusNode,
                      ),
                  ],
                ),
                if (episode.description != null &&
                    episode.description!.isNotEmpty) ...[
                  const SizedBox(height: LayoutConstants.spacingSm),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: Text(
                      episode.description!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
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
      ),
    );
  }

  Widget _buildActionButtons(
    BuildContext context,
    WidgetRef ref,
    File? downloadedFile,
    bool isDownloading,
    double downloadProgress,
    DownloadProgressData? downloadProgressData,
    MultimediaItem? details,
    FocusNode focusNode,
    FocusNode bodyFocusNode,
  ) {
    final rawDownload = _buildRawActionButton(
      context,
      ref,
      downloadedFile,
      isDownloading,
      downloadProgress,
      downloadProgressData,
      details,
    );
    if (rawDownload == null) return const SizedBox.shrink();

    final Widget downloadAction;
    // On desktop/TV the download icon stays visible for mouse clicks but
    // is NOT a separate D-pad focus target. Downloads are triggered via
    // Menu key or long-press OK (handled in the outer Focus.onKeyEvent).
    if (context.isDesktop) {
      downloadAction = ExcludeFocus(child: rawDownload);
    } else {
      downloadAction = _FocusableActionWrapper(
        focusNode: focusNode,
        bodyFocusNode: bodyFocusNode,
        child: rawDownload,
      );
    }

    final commentsTarget = isAnimeWitcherCommentItem(parentItem)
        ? animeWitcherEpisodeCommentTarget(parentItem, episode)
        : null;
    if (commentsTarget == null) return downloadAction;

    final commentsButton = IconButton(
      tooltip:
          Localizations.localeOf(context).languageCode.toLowerCase() == 'ar'
          ? 'تعليقات الحلقة'
          : 'Episode comments',
      icon: Icon(
        Icons.chat_bubble_outline_rounded,
        size: 27,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AnimeWitcherCommentsScreen(target: commentsTarget),
          ),
        );
      },
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        downloadAction,
        const SizedBox(height: 2),
        ExcludeFocus(child: commentsButton),
      ],
    );
  }

  Widget? _buildRawActionButton(
    BuildContext context,
    WidgetRef ref,
    File? downloadedFile,
    bool isDownloading,
    double downloadProgress,
    DownloadProgressData? downloadProgressData,
    MultimediaItem? details,
  ) {
    if (downloadedFile != null) {
      return IconButton(
        icon: const Icon(
          Icons.download_done_sharp,
          color: Colors.green,
          size: 32,
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: () {
          DownloadManagementDialog.show(
            context,
            details ?? parentItem,
            downloadedFile,
            episode: episode,
          );
        },
      );
    } else if (isDownloading) {
      return SizedBox(
        width: 32,
        height: 32,
        child: InkWell(
          onTap: () => DownloadProgressDialog.show(
            context,
            _downloadDialogTitle(parentItem, episode),
            episode.url,
          ),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: downloadProgressData?.status == TaskStatus.paused
                ? Icon(
                    Icons.pause_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: downloadProgress > 0 ? downloadProgress : null,
                        strokeWidth: 2,
                      ),
                      Text(
                        "${(downloadProgress * 100).toInt()}%", // Display the percentage
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      );
    } else {
      return IconButton(
        icon: Icon(
          Icons.file_download_outlined,
          size: 32,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: () {
          ref
              .read(downloadLauncherProvider)
              .launch(
                context,
                parentItem,
                episodeUrl: episode.url,
                episode: episode,
              );
        },
      );
    }
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
    final episodePosterUrl = AppImageFallbacks.optional(episode.posterUrl);
    // Prefer the episode still (AniZip). Falling back through CachedNetworkImage
    // errorWidget to the anime banner caused a visible flash: after leaving
    // the episodes tab the still is evicted, remount treats it as an error,
    // and the in-memory banner paints for a frame before AniZip returns.
    final imageUrl =
        episodePosterUrl ??
        AppImageFallbacks.episode(
          bannerUrl: parentItem.bannerUrl,
          posterUrl: parentItem.posterUrl,
          label: parentItem.title,
        );
    final placeholderColor = Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest;

    Widget buildThumbnailImage() {
      if (imageUrl == null || imageUrl.isEmpty) {
        return const ThumbnailErrorPlaceholder();
      }
      return ArtworkDecode(
        paintedWidth: 140,
        builder: (BuildContext context, int? decodeWidth) => CachedNetworkImage(
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

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 140,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: buildThumbnailImage(),
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
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.9),
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
}

/// Wraps the small download icon so D-pad / Tab focus is unmistakable when it
/// has focus (the IconButton's default focus ring is too subtle on TV).
class _FocusableActionWrapper extends StatefulWidget {
  final Widget child;
  final FocusNode focusNode;
  final FocusNode bodyFocusNode;
  const _FocusableActionWrapper({
    required this.child,
    required this.focusNode,
    required this.bodyFocusNode,
  });

  @override
  State<_FocusableActionWrapper> createState() =>
      _FocusableActionWrapperState();
}

class _FocusableActionWrapperState extends State<_FocusableActionWrapper> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) {
        // Left from the download icon returns focus to the card body.
        if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft &&
            widget.bodyFocusNode.canRequestFocus) {
          widget.bodyFocusNode.requestFocus();
          return KeyEventResult.handled;
        }
        // Enter/Select on the download icon activates it (the child
        // IconButton/InkWell already handles mouse tap, but D-pad
        // select events may not propagate to the IconButton.onPressed).
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          // Find and activate the nearest InkWell / IconButton child.
          // The child's onPressed is what we need to trigger.
          return KeyEventResult.ignored; // Let it bubble to the IconButton
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: _focused ? primary.withValues(alpha: 0.22) : null,
          border: Border.all(
            color: _focused ? primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}
