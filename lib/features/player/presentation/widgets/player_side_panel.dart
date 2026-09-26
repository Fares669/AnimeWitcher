import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:ui' show ImageFilter;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:collection/collection.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/storage/history_repository.dart';
import '../../../../core/storage/episode_watch_repository.dart';
import '../../../../core/account/account_providers.dart';
import '../../../../core/utils/download_time_remaining.dart' show DownloadProgressData;
import '../../../library/presentation/download_progress_v2_provider.dart';
import '../../../library/presentation/downloads_provider.dart';

import '../player_controller.dart';
import '../../../details/presentation/details_controller.dart';
import '../../../details/presentation/playback_launcher.dart';
import '../../../details/presentation/download_launcher.dart';
import '../../../details/presentation/downloaded_file_provider.dart';
import '../../../details/presentation/widgets/download_management_dialog.dart';
import '../../../details/presentation/widgets/download_progress_dialog.dart';
import '../../../details/presentation/widgets/episode_action_chip.dart';
import 'hotstar_player_style.dart';

import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:animewitcher/core/utils/episode_order.dart';

const List<Shadow> _kGlassTextShadow = [
  Shadow(color: Colors.black54, offset: Offset(0, 1.5), blurRadius: 3.0),
];

DownloadItem? _activeEpisodeDownload(
  List<DownloadItem> downloads,
  String episodeUrl,
) {
  final key = episodeUrl.trim();
  return downloads.firstWhereOrNull((item) {
    final matches =
        item.trackingUrl.trim() == key ||
        (item.episode?.url.trim() ?? '') == key;
    if (!matches) return false;
    return item.status != TaskStatus.complete &&
        item.status != TaskStatus.canceled;
  });
}

String _playerEpisodeDownloadTitle(MultimediaItem item, Episode episode) {
  final label = formatEpisodeLabel(
    episode: episode.episode,
    isArabic: true,
    title: episode.name,
    isFinal: episode.isFinal,
    serverName: episode.serverName,
  );
  return label.isEmpty ? item.title : '${item.title} - $label';
}

/// A reusable right-anchored drawer shell for the player.
///
/// Layout is a pure [Row] — an [Expanded] scrim on the left, the drawer surface
/// on the right — so there is no inner [Stack] and no magic-offset [Positioned].
/// The parent mounts it via a single `Positioned.fill` in the one overlay layer
/// that already sits over the video.
///
/// Visibility animates the drawer width (0 → [panel width]); the content is held
/// at full width by an [OverflowBox] pinned to the right edge, so it slides
/// cleanly from the right in both directions while staying mounted. Mounting
/// persists so the content can drive focus on open. While closed it ignores
/// pointers and is excluded from focus, so taps and D-pad fall through to the
/// chrome below.
class PlayerSidePanel extends StatelessWidget {
  final bool isVisible;
  final bool isTv;
  final VoidCallback onDismiss;
  final Widget child;

  const PlayerSidePanel({
    super.key,
    required this.isVisible,
    required this.onDismiss,
    required this.child,
    this.isTv = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isCompact = size.shortestSide < 600;
    final basePanelWidth = isCompact
        ? (size.width * 0.8).clamp(260.0, 380.0)
        : 350.0;
    // The episodes drawer needs more horizontal room than the source/track
    // drawers so its card layout can match the Episodes page. Keep the shared
    // shell unchanged for every other panel and widen episodes by exactly 25%.
    final widthScale = child is PlayerEpisodesPanel ? 1.25 : 1.0;
    final panelWidth = (basePanelWidth * widthScale)
        .clamp(260.0, size.width * 0.95)
        .toDouble();

    return IgnorePointer(
      ignoring: !isVisible,
      child: ExcludeFocus(
        excluding: !isVisible,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onDismiss,
                child: AnimatedContainer(
                  duration: HotstarPlayerStyle.controlFadeDuration,
                  color: Colors.black.withValues(alpha: isVisible ? 0.45 : 0.0),
                ),
              ),
            ),
            ClipRect(
              child: AnimatedContainer(
                duration: HotstarPlayerStyle.panelMotionDuration,
                curve: Curves.fastOutSlowIn,
                width: isVisible ? panelWidth : 0,
                child: OverflowBox(
                  alignment: Alignment.centerRight,
                  minWidth: panelWidth,
                  maxWidth: panelWidth,
                  child: _PanelSurface(
                    child: FocusTraversalGroup(
                      policy: WidgetOrderTraversalPolicy(),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PanelSurface extends StatelessWidget {
  final Widget child;

  const _PanelSurface({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.50),
            blurRadius: 50,
            spreadRadius: 0,
            offset: const Offset(-8, 0),
          ),
        ],
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22.0, sigmaY: 22.0),
              child: const DecoratedBox(
                decoration: BoxDecoration(color: Color(0xA6060608)),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.04),
                      Colors.white.withValues(alpha: 0.01),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.4, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.6, -0.7),
                    radius: 1.5,
                    colors: [
                      Colors.white.withValues(alpha: 0.02),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: ShaderMask(
                shaderCallback: (rect) {
                  return const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0.0, 0.15, 0.85, 1.0],
                  ).createShader(rect);
                },
                blendMode: BlendMode.dstIn,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        color: Colors.white.withValues(alpha: 0.12),
                        width: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: ShaderMask(
                shaderCallback: (rect) {
                  return const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0.0, 0.20, 0.80, 1.0],
                  ).createShader(rect);
                },
                blendMode: BlendMode.dstIn,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        color: Colors.white.withValues(alpha: 0.04),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

class PlayerEpisodesPanel extends ConsumerStatefulWidget {
  final MultimediaItem item;
  final bool isTv;
  final VoidCallback onClose;

  const PlayerEpisodesPanel({
    super.key,
    required this.item,
    required this.onClose,
    this.isTv = false,
  });

  @override
  ConsumerState<PlayerEpisodesPanel> createState() =>
      _PlayerEpisodesPanelState();
}

class _PlayerEpisodesPanelState extends ConsumerState<PlayerEpisodesPanel> {
  final FocusNode _anchorNode = FocusNode(debugLabel: 'episodes_panel_anchor');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(playerControllerProvider).showEpisodeList) {
        _focusAnchor();
      }
    });
  }

  @override
  void dispose() {
    _anchorNode.dispose();
    super.dispose();
  }

  void _focusAnchor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ref.read(playerControllerProvider).showEpisodeList) {
        return;
      }
      final ctx = _anchorNode.context;
      if (ctx != null) {
        _anchorNode.requestFocus();
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playerControllerProvider.select((s) => s.showEpisodeList), (
      prev,
      next,
    ) {
      if (next == true && prev != true && mounted) _focusAnchor();
    });

    final l10n = AppLocalizations.of(context)!;
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final panelDirection = isArabic ? TextDirection.rtl : TextDirection.ltr;
    final currentUrl =
        ref.watch(playerControllerProvider.select((s) => s.activeEpisodeUrl)) ??
        ref.read(playerControllerProvider.notifier).currentEpisodeUrl;
    var episodes = widget.item.episodes ?? const <Episode>[];
    final currentEpisode = episodes.firstWhereOrNull((e) => e.url == currentUrl);
    final isSeries =
        widget.item.contentType == MultimediaContentType.series ||
        widget.item.contentType == MultimediaContentType.anime;
    if (isSeries &&
        currentEpisode != null &&
        currentEpisode.dubStatus != DubStatus.none) {
      episodes = episodes
          .where((e) => e.dubStatus == currentEpisode.dubStatus)
          .toList();
    }
    episodes = episodesInDisplayOrder(
      episodes,
      ascending: ref.watch(
        detailsControllerProvider(
          widget.item.url,
        ).select((state) => state.isAscending),
      ),
    );
    final historyRepo = ref.read(historyRepositoryProvider);
    ref.watch(episodeWatchRevisionProvider);
    ref.watch(accountDataRevisionProvider);
    final episodeWatchRepo = ref.watch(episodeWatchRepositoryProvider);

    final seasons = episodes.map((e) => e.season).toSet().toList()..sort();
    final multiSeason = seasons.length > 1;

    final rows = <Widget>[];
    var anchorAssigned = false;
    for (final season in seasons) {
      final seasonEps = episodes.where((e) => e.season == season).toList();
      if (multiSeason) {
        rows.add(_PanelSubheader(title: l10n.seasonWithNumber(season)));
      }
      for (final ep in seasonEps) {
        final isCurrent = ep.url == currentUrl;
        final isAnchor = isCurrent && !anchorAssigned;
        if (isAnchor) anchorAssigned = true;
        final pos = historyRepo.getEpisodePosition(
          ep.url,
          mainUrl: widget.item.url,
          season: ep.season,
          episode: ep.episode,
        );
        final dur = historyRepo.getEpisodeDuration(
          ep.url,
          mainUrl: widget.item.url,
          season: ep.season,
          episode: ep.episode,
        );
        final isWatched = episodeWatchRepo.isWatched(widget.item.url, ep);
        rows.add(
          _EpisodeRow(
            parentItem: widget.item,
            episode: ep,
            isCurrent: isCurrent,
            isWatched: isWatched,
            progress: isWatched
                ? 1.0
                : (dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0),
            isTv: widget.isTv,
            focusNode: isAnchor ? _anchorNode : null,
            onTap: () async {
              widget.onClose();
              final selected = await ref
                  .read(playbackLauncherProvider)
                  .chooseSourceForItem(
                    context,
                    widget.item,
                    ep.url,
                    episode: ep,
                  );
              if (selected == null || !mounted) return;
              await ref
                  .read(playerControllerProvider.notifier)
                  .loadEpisode(ep, selectedSource: selected);
            },
          ),
        );
      }
    }
    return SafeArea(
      left: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: isArabic
                ? const EdgeInsets.fromLTRB(4, 12, 20, 12)
                : const EdgeInsets.fromLTRB(20, 12, 4, 12),
            child: Directionality(
              textDirection: panelDirection,
              child: Row(
                children: [
                  const Icon(
                    Icons.video_library_outlined,
                    color: Colors.white,
                    size: 22,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      l10n.episodes,
                      textAlign: TextAlign.start,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: HotstarPlayerStyle.primaryText,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                        shadows: _kGlassTextShadow,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 38,
                      minHeight: 38,
                    ),
                    padding: EdgeInsets.zero,
                    iconSize: 22,
                    icon: const Icon(Icons.close_rounded),
                    color: HotstarPlayerStyle.secondaryText,
                  ),
                ],
              ),
            ),
          ),
          const Divider(color: HotstarPlayerStyle.divider, height: 1),
          Expanded(
            child: episodes.isEmpty
                ? _EmptyHint(text: l10n.noEpisodesFound)
                : _OptionList(children: rows),
          ),
        ],
      ),
    );
  }
}

class _EpisodeRow extends ConsumerStatefulWidget {
  final MultimediaItem parentItem;
  final Episode episode;
  final bool isCurrent;
  final bool isWatched;
  final double progress;
  final bool isTv;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _EpisodeRow({
    required this.parentItem,
    required this.episode,
    required this.isCurrent,
    required this.isWatched,
    required this.progress,
    required this.isTv,
    required this.onTap,
    this.focusNode,
  });

  @override
  ConsumerState<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends ConsumerState<_EpisodeRow> {
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _queueDownloadedFileCheck();
  }

  @override
  void didUpdateWidget(covariant _EpisodeRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.episode.url != widget.episode.url ||
        oldWidget.parentItem.url != widget.parentItem.url) {
      _queueDownloadedFileCheck();
    }
  }

  void _queueDownloadedFileCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final downloads =
          ref.read(downloadsProvider).value ?? const <DownloadItem>[];
      if (_activeEpisodeDownload(downloads, widget.episode.url) != null) return;
      ref
          .read(downloadedFilesProvider.notifier)
          .checkFile(widget.parentItem, episode: widget.episode);
    });
  }

  Widget _buildDownloadAction(
    BuildContext context, {
    required File? downloadedFile,
    required bool isDownloading,
    required double downloadProgress,
    required DownloadProgressData? progressData,
    required VoidCallback onPressed,
  }) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

    if (downloadedFile != null) {
      return EpisodeActionChip(
        tooltip: isArabic ? 'تم التنزيل' : 'Downloaded',
        icon: Icons.download_done_rounded,
        color: const Color(0xFF4CAF50),
        onPressed: onPressed,
      );
    }

    if (isDownloading) {
      return EpisodeActionChip(
        tooltip: isArabic ? 'جارٍ التنزيل' : 'Downloading',
        onPressed: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: progressData?.status == TaskStatus.paused
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
                      '${(downloadProgress * 100).toInt()}%',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
        ),
      );
    }

    return EpisodeActionChip(
      tooltip: isArabic ? 'تنزيل الحلقة' : 'Download episode',
      icon: Icons.save_alt_rounded,
      onPressed: onPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final downloads =
        ref.watch(downloadsProvider).value ?? const <DownloadItem>[];
    final activeDownload = _activeEpisodeDownload(downloads, ep.url);
    final isDownloading = activeDownload != null;
    final progressMap = ref.watch(downloadProgressProvider);
    final logicalId = activeDownload?.logicalId?.trim();
    final progressData = logicalId != null && logicalId.isNotEmpty
        ? progressMap[logicalId]
        : progressMap[ep.url];
    final downloadProgress =
        progressData?.progress ?? activeDownload?.progress ?? 0.0;
    final downloadedFile = ref.watch(downloadedFilesProvider)[ep.url];
    ref.listen(downloadsProvider, (previous, next) {
      final wasDownloading = _activeEpisodeDownload(
            previous?.value ?? const <DownloadItem>[],
            ep.url,
          ) !=
          null;
      final isStillDownloading = _activeEpisodeDownload(
            next.value ?? const <DownloadItem>[],
            ep.url,
          ) !=
          null;
      if (wasDownloading && !isStillDownloading) {
        _queueDownloadedFileCheck();
      }
    });

    void triggerDownload() {
      if (downloadedFile != null) {
        DownloadManagementDialog.show(
          context,
          widget.parentItem,
          downloadedFile,
          episode: ep,
        );
      } else if (isDownloading) {
        DownloadProgressDialog.show(
          context,
          _playerEpisodeDownloadTitle(widget.parentItem, ep),
          ep.url,
        );
      } else {
        ref.read(downloadLauncherProvider).launch(
          context,
          widget.parentItem,
          episodeUrl: ep.url,
          episode: ep,
        );
      }
    }

    final showHighlight = _focused || _hovered;
    final ring = _focused && widget.isTv;
    const accent = HotstarPlayerStyle.accent;
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final rowDirection = isArabic ? TextDirection.rtl : TextDirection.ltr;
    return Semantics(
      button: true,
      selected: widget.isCurrent,
      label: ep.name,
      child: Focus(
        focusNode: widget.focusNode,
        onFocusChange: (v) => setState(() => _focused = v),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: HotstarPlayerStyle.fastMotionDuration,
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: _panelRowDecoration(
                focusedOnTv: ring,
                selected: widget.isCurrent,
                hovered: showHighlight,
              ),
              child: Directionality(
                textDirection: rowDirection,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _EpisodeThumbnail(
                      posterUrl: ep.posterUrl,
                      isCurrent: widget.isCurrent,
                      isWatched: widget.isWatched,
                      progress: widget.progress,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  formatEpisodePrimaryLabel(
                                    episode: ep.episode,
                                    isArabic: isArabic,
                                    isFinal: ep.isFinal,
                                    serverName: ep.serverName,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.start,
                                  style: TextStyle(
                                    color: widget.isCurrent
                                        ? HotstarPlayerStyle.primaryText
                                        : HotstarPlayerStyle.secondaryText,
                                    fontSize: 14,
                                    fontWeight: widget.isCurrent
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                    shadows: _kGlassTextShadow,
                                  ),
                                ),
                              ),
                              if (ep.isFiller) ...[
                                const SizedBox(width: 6),
                                const _FillerBadge(),
                              ],
                              if (ep.dubStatus != DubStatus.none &&
                                  !isStandaloneEpisodeLabel(ep.serverName)) ...[
                                const SizedBox(width: 6),
                                _DubBadge(
                                  dubStatus: ep.dubStatus,
                                  isCurrent: widget.isCurrent,
                                ),
                              ],
                            ],
                          ),
                          if (realEpisodeTitle(ep.name).isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              realEpisodeTitle(ep.name),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.start,
                              style: TextStyle(
                                color: widget.isCurrent
                                    ? accent
                                    : HotstarPlayerStyle.mutedText,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                shadows: _kGlassTextShadow,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 34,
                      child: ExcludeFocus(
                        child: _buildDownloadAction(
                          context,
                          downloadedFile: downloadedFile,
                          isDownloading: isDownloading,
                          downloadProgress: downloadProgress,
                          progressData: progressData,
                          onPressed: triggerDownload,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FillerBadge extends StatelessWidget {
  const _FillerBadge();

  @override
  Widget build(BuildContext context) {
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFD32F2F),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isArabic ? 'فلر' : 'FILLER',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          height: 1.1,
        ),
      ),
    );
  }
}

class _DubBadge extends StatelessWidget {
  final DubStatus dubStatus;
  final bool isCurrent;

  const _DubBadge({required this.dubStatus, required this.isCurrent});

  @override
  Widget build(BuildContext context) {
    final isSub = dubStatus == DubStatus.subbed;
    final label = isSub
        ? AppLocalizations.of(context)!.sub.toUpperCase()
        : AppLocalizations.of(context)!.dub.toUpperCase();
    final tint = isSub ? const Color(0xFF64B5F6) : const Color(0xFFFFB74D);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: isCurrent ? 0.22 : 0.14),
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            offset: const Offset(0, 1),
            blurRadius: 2,
          ),
          BoxShadow(
            color: tint.withValues(alpha: 0.18),
            offset: const Offset(0, -0.5),
            blurRadius: 1,
            spreadRadius: 0,
          ),
        ],
        border: Border.all(color: tint.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: isCurrent ? tint : tint.withValues(alpha: 0.85),
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
          height: 1.2,
          shadows: _kGlassTextShadow,
        ),
      ),
    );
  }
}

class _EpisodeThumbnail extends StatelessWidget {
  final String? posterUrl;
  final bool isCurrent;
  final bool isWatched;
  final double progress;

  const _EpisodeThumbnail({
    required this.posterUrl,
    required this.isCurrent,
    required this.isWatched,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final hasPoster = posterUrl != null && posterUrl!.isNotEmpty;
    final hasProgress = !isWatched && progress > 0.02 && progress < 0.98;
    final watchedLabel = AppLocalizations.of(context)!.watched.toUpperCase();
    final accent = Theme.of(context).colorScheme.primary;
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 104,
          height: 58,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (hasPoster)
                ArtworkDecode(
                  paintedWidth: 104,
                  builder: (BuildContext context, int? decodeWidth) =>
                      CachedNetworkImage(
                        imageUrl: posterUrl!,
                        fit: BoxFit.cover,
                        memCacheWidth: decodeWidth,
                        filterQuality: FilterQuality.medium,
                        fadeInDuration: Duration.zero,
                        fadeOutDuration: Duration.zero,
                        placeholder: (_, _) => const _ThumbPlaceholder(),
                        errorWidget: (_, _, _) => const _ThumbPlaceholder(),
                      ),
                )
              else
                const _ThumbPlaceholder(),
              if (isWatched)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.28),
                  ),
                ),
              if (isCurrent)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              if (isWatched)
                Positioned(
                  top: 5,
                  left: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      watchedLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                        shadows: _kGlassTextShadow,
                      ),
                    ),
                  ),
                ),
              if (isWatched || hasProgress)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: LinearProgressIndicator(
                    value: isWatched ? 1.0 : progress,
                    minHeight: 3,
                    backgroundColor: Colors.white24,
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0x14FFFFFF),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: HotstarPlayerStyle.mutedText,
          size: 22,
        ),
      ),
    );
  }
}

class _OptionList extends StatelessWidget {
  final List<Widget> children;

  const _OptionList({required this.children});

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
        children: children,
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Text(
          text,
          textAlign: TextAlign.start,
          style: const TextStyle(
            color: HotstarPlayerStyle.mutedText,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            shadows: _kGlassTextShadow,
          ),
        ),
      ),
    );
  }
}

BoxDecoration _panelRowDecoration({
  required bool focusedOnTv,
  required bool selected,
  required bool hovered,
}) {
  const accent = HotstarPlayerStyle.accent;
  final Color bg;
  if (focusedOnTv) {
    bg = accent.withValues(alpha: 0.30);
  } else if (selected) {
    bg = accent.withValues(alpha: 0.14);
  } else if (hovered) {
    bg = Colors.white.withValues(alpha: 0.08);
  } else {
    bg = Colors.transparent;
  }
  return BoxDecoration(
    color: bg,
    borderRadius: BorderRadius.circular(8),
    border: Border.all(
      color: focusedOnTv ? accent : Colors.transparent,
      width: 2,
    ),
    boxShadow: focusedOnTv
        ? [BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: 12)]
        : null,
  );
}

class _PanelSubheader extends StatelessWidget {
  final String title;

  const _PanelSubheader({required this.title});

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        child: Text(
          title.toUpperCase(),
          textAlign: TextAlign.start,
          style: const TextStyle(
            color: HotstarPlayerStyle.mutedText,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            shadows: _kGlassTextShadow,
          ),
        ),
      ),
    );
  }
}
