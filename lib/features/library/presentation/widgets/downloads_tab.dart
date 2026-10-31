import 'dart:async';

import '../../../../shared/widgets/confirm_dialog.dart';

import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/app_side_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/core/utils/image_fallbacks.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:animewitcher/core/utils/episode_order.dart';
import 'package:animewitcher/core/providers/episode_sort_provider.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/services/download_v2/download_continued_processing_v2.dart';
import '../../../../core/services/download_v2/download_v2_models.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/services/download_concurrency.dart';
import '../../../../core/services/download_parallel.dart';
import 'segmented_download_progress.dart';
import 'completed_download_episode_card.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../details/presentation/downloaded_file_provider.dart';
import '../../../details/presentation/playback_launcher.dart';
import '../download_progress_v2_provider.dart';
import '../download_delete_confirmation.dart';
import '../downloads_provider.dart';
import '../download_episode_artwork.dart';
import '../download_unit_count_label.dart';
import 'completed_download_chapter_card.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/utils/file_size_formatter.dart';
import '../../../../core/utils/download_progress_data.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../../../../shared/widgets/underline_segment_tabs.dart';

MultimediaItem _savedPlaybackItem(
  DownloadItem selected,
  Iterable<DownloadItem> downloads,
) {
  String mediaIdentity(MultimediaItem item) =>
      item.tmdbId?.toString() ??
      ((item.imdbId?.trim().isNotEmpty ?? false)
          ? item.imdbId!.trim()
          : item.url.trim());
  final media = mediaIdentity(selected.item);
  final episodes = <String, Episode>{
    for (final episode in selected.item.episodes ?? const <Episode>[])
      if (episode.url.trim().isNotEmpty) episode.url.trim(): episode,
  };
  for (final download in downloads) {
    final episode = download.episode;
    if (download.status == TaskStatus.complete &&
        media.isNotEmpty &&
        mediaIdentity(download.item) == media &&
        episode != null &&
        episode.url.trim().isNotEmpty) {
      episodes[episode.url.trim()] = episode;
    }
  }
  final current = selected.episode;
  if (current != null && current.url.trim().isNotEmpty) {
    episodes[current.url.trim()] = current;
  }
  return episodes.isEmpty
      ? selected.item
      : selected.item.copyWith(
          episodes: episodeItemsInDisplayOrder(
            episodes.values.toList(),
            episodeOf: (episode) => episode,
            ascending: true,
          ),
        );
}

Future<String?> _resolveLocalPlaybackUrl(
  WidgetRef ref,
  DownloadItem item,
) async {
  final file = await ref
      .read(downloadedFilesProvider.notifier)
      .resolveFile(item.item, episode: item.episode, logicalId: item.logicalId);
  return file?.path;
}

Future<void> _removeMissingDownload(
  BuildContext context,
  WidgetRef ref,
  DownloadItem item,
  AppLocalizations l10n,
) async {
  if (!context.mounted) return;
  ref.read(notificationServiceProvider).showError(l10n.fileNotFoundRemoving);
  await ref.read(downloadsProvider.notifier).removeDownload(item);
}

class DownloadsTab extends ConsumerStatefulWidget {
  const DownloadsTab({super.key, this.headerPadding = EdgeInsets.zero});

  final EdgeInsetsGeometry headerPadding;

  @override
  ConsumerState<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends ConsumerState<DownloadsTab>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  late final TabController _tabs;
  final Set<String> _selectedIds = <String>{};
  bool _bulkInFlight = false;
  int _tabIndex = 0;

  void _toggleSelected(DownloadItem item) {
    setState(() {
      if (!_selectedIds.add(item.id)) {
        _selectedIds.remove(item.id);
      }
    });
  }

  void _toggleGroupSelection(List<DownloadItem> items) {
    setState(() {
      if (items.every((item) => _selectedIds.contains(item.id))) {
        _selectedIds.removeAll(items.map((item) => item.id));
      } else {
        _selectedIds.addAll(items.map((item) => item.id));
      }
    });
  }

  Future<void> _bulkAction(List<DownloadItem> items, String action) async {
    if (_bulkInFlight || items.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    if (action == 'delete') {
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.deleteDownload,
        message:
            '${items.length} ${appText(context, english: 'downloads will be deleted.', arabic: 'تنزيل سيتم حذفه.')} ',
        confirmLabel: l10n.delete,
        cancelLabel: l10n.cancel,
      );
      if (!confirmed || !mounted) return;
    }
    setState(() => _bulkInFlight = true);
    var failed = 0;
    final notifier = ref.read(downloadsProvider.notifier);
    final notifications = ref.read(notificationServiceProvider);
    try {
      if (action == 'delete') {
        if (!await notifier.removeDownloads(items)) failed++;
        if (mounted) {
          final latest = ref.read(downloadsProvider);
          if (latest.hasValue) {
            final remainingIds = (latest.value ?? const <DownloadItem>[])
                .map((item) => item.id)
                .toSet();
            setState(() => _selectedIds.retainAll(remainingIds));
          }
        }
      } else {
        for (final item in items) {
          try {
            if (action == 'pause' &&
                (item.status == TaskStatus.running ||
                    item.status == TaskStatus.enqueued ||
                    item.status == TaskStatus.waitingToRetry)) {
              await notifier.pauseDownload(item.id);
            } else if (action == 'resume' && item.status == TaskStatus.paused) {
              await notifier.resumeDownload(item.id);
            }
          } catch (error) {
            failed++;
            showDownloadActionError(notifications, error);
          }
        }
      }
      if (failed > 0) {
        notifications.showError('تعذر تنفيذ العملية على $failed تنزيل');
      }
    } catch (error) {
      showDownloadActionError(notifications, error);
    } finally {
      if (mounted) setState(() => _bulkInFlight = false);
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(_handleTabChanged);
  }

  void _handleTabChanged() {
    if (!mounted || _tabs.index == _tabIndex) return;
    setState(() {
      _tabIndex = _tabs.index;
      _selectedIds.clear();
    });
  }

  Widget _buildSelectionBar({
    required List<DownloadItem> selected,
    required List<DownloadItem> currentDownloads,
    required bool canPause,
    required bool canResume,
    required AppLocalizations l10n,
  }) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      key: const ValueKey('downloads-selection-bar'),
      top: false,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(
          elevation: 10,
          shadowColor: Colors.black.withValues(alpha: 0.30),
          color: colors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.checklist_rounded,
                      color: colors.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${selected.length} ${appText(context, english: 'selected', arabic: 'محدد')}',
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('downloads-clear-selection'),
                      tooltip: appText(
                        context,
                        english: 'Clear selection',
                        arabic: 'إلغاء التحديد',
                      ),
                      onPressed: () => setState(_selectedIds.clear),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: const Size(0, 48),
                        ),
                        onPressed: _bulkInFlight
                            ? null
                            : () => _bulkAction(selected, 'delete'),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 19,
                        ),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(l10n.delete),
                        ),
                      ),
                    ),
                    if (_tabIndex == 0) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 48),
                          ),
                          onPressed: _bulkInFlight || !canPause
                              ? null
                              : () => _bulkAction(selected, 'pause'),
                          icon: const Icon(Icons.pause_rounded, size: 19),
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              appText(
                                context,
                                english: 'Pause',
                                arabic: 'إيقاف',
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 48),
                          ),
                          onPressed: _bulkInFlight || !canResume
                              ? null
                              : () => _bulkAction(selected, 'resume'),
                          icon: const Icon(Icons.play_arrow_rounded, size: 19),
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              appText(
                                context,
                                english: 'Resume',
                                arabic: 'إكمال',
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      key: const ValueKey('downloads-select-all'),
                      tooltip: appText(
                        context,
                        english: 'Select all',
                        arabic: 'تحديد الكل',
                      ),
                      onPressed: () => _toggleGroupSelection(currentDownloads),
                      icon: const Icon(Icons.select_all_rounded),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        maximumSize: const Size(48, 48),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabs.removeListener(_handleTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final downloadsAsync = ref.watch(downloadsProvider);
    final activeProgress = ref.watch(downloadProgressProvider);
    final l10n = AppLocalizations.of(context)!;

    // Keep local completed rows available through refreshes and transport errors.
    final visibleDownloads = collapseDuplicateDownloads(
      downloadsAsync.hasValue
          ? downloadsAsync.value ?? const <DownloadItem>[]
          : const <DownloadItem>[],
    ).visible;
    final completed = visibleDownloads
        .where((item) => !isActiveDownloadStatus(item.status))
        .toList();
    final active = visibleDownloads
        .where((item) => isActiveDownloadStatus(item.status))
        .toList();
    final currentDownloads = _tabIndex == 0 ? active : completed;
    final selected = currentDownloads
        .where((item) => _selectedIds.contains(item.id))
        .toList();
    final currentSelectedIds = selected.map((item) => item.id).toSet();
    final canPause = selected.any(
      (item) =>
          item.status == TaskStatus.running ||
          item.status == TaskStatus.enqueued ||
          item.status == TaskStatus.waitingToRetry,
    );
    final canResume = selected.any((item) => item.status == TaskStatus.paused);
    final controllableActive = active
        .where(
          (item) =>
              item.status == TaskStatus.running ||
              item.status == TaskStatus.enqueued ||
              item.status == TaskStatus.waitingToRetry ||
              item.status == TaskStatus.paused,
        )
        .toList();
    final allPaused =
        controllableActive.isNotEmpty &&
        controllableActive.every((item) => item.status == TaskStatus.paused);
    // RTL only for the tab strip + pager swipe (like المواسم). Each
    // pane is LTR so cards stay poster-left — do not mirror the page.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: widget.headerPadding,
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Row(
              children: [
                Expanded(
                  child: FilterStyleTabBar(
                    controller: _tabs,
                    isScrollable: false,
                    tabs: [
                      FilterStyleTab(label: l10n.downloads),
                      FilterStyleTab(label: l10n.downloadsTabCompleted),
                    ],
                  ),
                ),
                // The side menu's button, in the corner it comes from.
                const AppSideMenuButton(
                  padding: EdgeInsetsDirectional.only(start: 4, end: 12),
                ),
              ],
            ),
          ),
        ),
        const _DownloadSessionStrip(),
        if (_tabIndex == 0 &&
            currentDownloads.isNotEmpty &&
            currentSelectedIds.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('downloads-delete-all'),
                      onPressed: _bulkInFlight
                          ? null
                          : () => _bulkAction(currentDownloads, 'delete'),
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: Text(
                        appText(
                          context,
                          english: 'Delete all',
                          arabic: 'حذف الكل',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('downloads-pause-resume-all'),
                      onPressed: _bulkInFlight || controllableActive.isEmpty
                          ? null
                          : () => _bulkAction(
                              controllableActive,
                              allPaused ? 'resume' : 'pause',
                            ),
                      icon: Icon(
                        allPaused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                      ),
                      label: Text(
                        allPaused
                            ? appText(
                                context,
                                english: 'Resume all',
                                arabic: 'إكمال الكل',
                              )
                            : appText(
                                context,
                                english: 'Pause all',
                                arabic: 'إيقاف الكل',
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: TabBarView(
              controller: _tabs,
              children: [
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: downloadsAsync.when(
                    skipLoadingOnRefresh: false,
                    skipLoadingOnReload: false,
                    data: (_) => _ActiveDownloadsList(
                      items: active,
                      activeProgress: activeProgress,
                      emptyMessage: l10n.noDownloadsYet,
                      selectedIds: currentSelectedIds,
                      onToggleSelection: _toggleSelected,
                    ),
                    loading: () => const Center(child: AppLoadingIndicator()),
                    error: (err, stack) =>
                        Center(child: Text(l10n.errorPrefix(err.toString()))),
                  ),
                ),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: _CompletedDownloadsList(
                    items: completed,
                    emptyMessage: l10n.noCompletedDownloadsYet,
                    selectedIds: currentSelectedIds,
                    onToggleSelection: _toggleSelected,
                    onToggleGroupSelection: _toggleGroupSelection,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: currentSelectedIds.isEmpty
              ? const SizedBox.shrink(
                  key: ValueKey('downloads-selection-empty'),
                )
              : Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 8),
                  child: _buildSelectionBar(
                    selected: selected,
                    currentDownloads: currentDownloads,
                    canPause: canPause,
                    canResume: canResume,
                    l10n: l10n,
                  ),
                ),
        ),
      ],
    );
  }
}

/// Compact session strip under the tab header: "يتم تنزيل x من y" with the
/// TOTAL throughput of all active downloads on the left. Per-download speed
/// is never shown; the strip disappears when no session is active.
class _DownloadSessionStrip extends StatelessWidget {
  const _DownloadSessionStrip();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DownloadSessionSummaryV2>(
      valueListenable: downloadSessionSummaryNotifier,
      builder: (context, summary, _) {
        if (!summary.isActive) return const SizedBox.shrink();
        final style = Theme.of(context).textTheme.bodyMedium
            ?.copyWith(fontWeight: FontWeight.w600);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    appText(
                      context,
                      english:
                          'Downloading ${summary.currentIndex} of ${summary.batchTotal}',
                      arabic:
                          'يتم تنزيل ${summary.currentIndex} من ${summary.batchTotal}',
                    ),
                    style: style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  formatTotalDownloadSpeed(summary.totalSpeedBytesPerSecond),
                  textDirection: TextDirection.ltr,
                  style: style,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The one download speed the app displays: total bytes per second across
/// every active download, formatted like "274KB/s" / "1.2MB/s".
String formatTotalDownloadSpeed(double bytesPerSecond) {
  if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) return '0 KB/s';
  final kiloBytes = bytesPerSecond / 1000;
  if (kiloBytes < 1000) return '${kiloBytes.round()}KB/s';
  return '${(kiloBytes / 1000).toStringAsFixed(1)}MB/s';
}

class _DownloadsEmptyState extends StatelessWidget {
  const _DownloadsEmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.download_for_offline_outlined,
            size: 64,
            color: Theme.of(context).dividerColor,
          ),
          const SizedBox(height: 16),
          Text(message, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}

class _ActiveDownloadsList extends StatelessWidget {
  const _ActiveDownloadsList({
    required this.items,
    required this.activeProgress,
    required this.emptyMessage,
    required this.selectedIds,
    required this.onToggleSelection,
  });

  final List<DownloadItem> items;
  final Map<String, DownloadProgressData> activeProgress;
  final String emptyMessage;
  final Set<String> selectedIds;
  final ValueChanged<DownloadItem> onToggleSelection;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _DownloadsEmptyState(message: emptyMessage);
    }

    return Directionality(
      textDirection: TextDirection.ltr,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(height: 16),
        itemBuilder: (context, index) {
          final download = items[index];
          final logicalId = download.logicalId?.trim();
          final trackingUrl = download.task.metaData.isNotEmpty
              ? download.task.metaData
              : download.task.url;
          final progressData = logicalId?.isNotEmpty == true
              ? activeProgress[logicalId]
              : activeProgress[trackingUrl];
          final double displayProgress =
              progressData?.progress ?? download.progress;
          final TaskStatus displayStatus =
              progressData?.status ?? download.status;

          return _DownloadItemTile(
            key: ValueKey(download.id),
            item: download,
            progress: displayProgress,
            status: displayStatus,
            progressData: progressData,
            selecting: selectedIds.isNotEmpty,
            selected: selectedIds.contains(download.id),
            onToggleSelection: () => onToggleSelection(download),
          );
        },
      ),
    );
  }
}

class _CompletedDownloadsList extends StatelessWidget {
  const _CompletedDownloadsList({
    required this.items,
    required this.emptyMessage,
    required this.selectedIds,
    required this.onToggleSelection,
    required this.onToggleGroupSelection,
  });

  final List<DownloadItem> items;
  final String emptyMessage;
  final Set<String> selectedIds;
  final ValueChanged<DownloadItem> onToggleSelection;
  final ValueChanged<List<DownloadItem>> onToggleGroupSelection;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _DownloadsEmptyState(message: emptyMessage);
    }

    final Map<String, List<DownloadItem>> grouped = {};
    final List<String> keys = [];
    for (final item in items) {
      final mediaIdentity =
          item.item.tmdbId?.toString() ??
          (item.item.url.trim().isNotEmpty
              ? item.item.url.trim()
              : item.item.title);
      final key = '${item.mediaKind.name}:$mediaIdentity';
      if (!grouped.containsKey(key)) {
        keys.add(key);
        grouped[key] = [];
      }
      grouped[key]!.add(item);
    }

    return Directionality(
      textDirection: TextDirection.ltr,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        itemCount: keys.length,
        separatorBuilder: (context, index) => const SizedBox(height: 16),
        itemBuilder: (context, index) {
          final key = keys[index];
          return _GroupedDownloadTile(
            key: ValueKey(key),
            items: grouped[key]!,
            selectedIds: selectedIds,
            onToggleSelection: onToggleSelection,
            onToggleGroupSelection: onToggleGroupSelection,
          );
        },
      ),
    );
  }
}

class _GroupedDownloadTile extends ConsumerStatefulWidget {
  final List<DownloadItem> items;
  final Set<String> selectedIds;
  final ValueChanged<DownloadItem> onToggleSelection;
  final ValueChanged<List<DownloadItem>> onToggleGroupSelection;

  const _GroupedDownloadTile({
    super.key,
    required this.items,
    required this.selectedIds,
    required this.onToggleSelection,
    required this.onToggleGroupSelection,
  });

  @override
  ConsumerState<_GroupedDownloadTile> createState() =>
      _GroupedDownloadTileState();
}

class _GroupedDownloadTileState extends ConsumerState<_GroupedDownloadTile> {
  late Future<File?> _poster;
  bool _deleteInFlight = false;
  List<DownloadItem> get items => widget.items;

  String _artworkId(DownloadItem item) {
    final logical = item.logicalId?.trim() ?? '';
    return logical.isEmpty ? item.id : logical;
  }

  String _posterKey(List<DownloadItem> values) => values
      .map(
        (item) =>
            '${_artworkId(item)}:${item.artworkMetadataVerified}:${item.item.posterUrl}',
      )
      .join('|');

  @override
  void initState() {
    super.initState();
    _poster = _loadPoster();
  }

  @override
  void didUpdateWidget(covariant _GroupedDownloadTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_posterKey(oldWidget.items) != _posterKey(items)) {
      _poster = _loadPoster();
    }
  }

  Future<File?> _loadPoster() async {
    // A group's first row may lack artwork while another retained copy exists.
    for (final item in items) {
      final saved = await existingDownloadedPosterArtwork(_artworkId(item));
      if (saved != null) return saved;
    }
    for (final item in items) {
      if (!item.artworkMetadataVerified) continue;
      final saved = await ensureDownloadedPosterArtwork(
        logicalId: _artworkId(item),
        posterUrl: item.item.posterUrl,
      );
      if (saved != null) return saved;
    }
    return null;
  }

  Widget _posterPlaceholder(ThemeData theme) => Container(
    width: 80,
    height: 120,
    color: theme.dividerColor,
    child: const Icon(Icons.movie_outlined),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final firstItem = items.first;
    final episodeSortAscending = ref.watch(episodeSortAscendingProvider);
    final isManga = firstItem.mediaKind == DownloadMediaKind.mangaChapter;

    final orderedItems = isManga
        ? (List<DownloadItem>.from(items)..sort((a, b) {
            final an = a.chapter?.number;
            final bn = b.chapter?.number;
            if (an != null && bn != null) {
              final compare = an.compareTo(bn);
              if (compare != 0) {
                return episodeSortAscending ? compare : -compare;
              }
            }
            final compare = (a.chapter?.name ?? '').compareTo(
              b.chapter?.name ?? '',
            );
            return episodeSortAscending ? compare : -compare;
          }))
        : episodeItemsInDisplayOrder(
            items,
            episodeOf: (item) => item.episode,
            ascending: episodeSortAscending,
          );

    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LayoutConstants.radiusXl),
        side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        backgroundColor: Colors.transparent,
        collapsedBackgroundColor: Colors.transparent,
        tilePadding: const EdgeInsets.symmetric(
          horizontal: LayoutConstants.spacingMd,
          vertical: LayoutConstants.spacingXs,
        ),
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: () => widget.onToggleGroupSelection(items),
          child: Row(
            textDirection: TextDirection.ltr,
            children: [
              if (widget.selectedIds.isNotEmpty)
                Checkbox(
                  tristate: true,
                  value:
                      items.every(
                        (item) => widget.selectedIds.contains(item.id),
                      )
                      ? true
                      : items.any(
                          (item) => widget.selectedIds.contains(item.id),
                        )
                      ? null
                      : false,
                  onChanged: (_) => widget.onToggleGroupSelection(items),
                ),
              ClipRRect(
                borderRadius: BorderRadius.circular(LayoutConstants.radiusMd),
                child: ArtworkDecode(
                  paintedWidth: 80,
                  builder: (BuildContext context, int? decodeWidth) =>
                      FutureBuilder<File?>(
                        future: _poster,
                        builder: (context, snapshot) {
                          final saved = snapshot.data;
                          if (saved != null) {
                            return Image.file(
                              saved,
                              width: 80,
                              height: 120,
                              fit: BoxFit.cover,
                              cacheWidth: decodeWidth,
                              filterQuality: FilterQuality.medium,
                              errorBuilder: (_, _, _) =>
                                  _posterPlaceholder(theme),
                            );
                          }
                          return CachedNetworkImage(
                            imageUrl:
                                AppImageFallbacks.poster(
                                  firstItem.item.posterUrl,
                                ) ??
                                '',
                            width: 80,
                            height: 120,
                            fit: BoxFit.cover,
                            memCacheWidth: decodeWidth,
                            filterQuality: FilterQuality.medium,
                            errorWidget: (_, _, _) => _posterPlaceholder(theme),
                          );
                        },
                      ),
                ),
              ),
              const SizedBox(width: LayoutConstants.spacingMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      firstItem.item.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          Icons.library_books_rounded,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          completedDownloadUnitCountLabel(
                            kind: firstItem.mediaKind,
                            count: items.length,
                          ),
                          // The card stays poster-left, but an Arabic count
                          // needs its own RTL paragraph for number/noun order.
                          textDirection: TextDirection.rtl,
                          textAlign: TextAlign.left,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: LayoutConstants.spacingSm),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: widget.selectedIds.isNotEmpty
                    ? () => widget.onToggleGroupSelection(items)
                    : _deleteInFlight
                    ? null
                    : () => _confirmDeleteAll(context, ref),
                color: theme.colorScheme.error.withValues(alpha: 0.8),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        children: orderedItems.asMap().entries.map((entry) {
          final download = entry.value;
          final isLast = entry.key == orderedItems.length - 1;

          return Column(
            children: [
              if (entry.key == 0)
                Divider(
                  height: 1,
                  color: theme.dividerColor.withValues(alpha: 0.4),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: LayoutConstants.spacingMd,
                  vertical: LayoutConstants.spacingSm,
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => widget.onToggleSelection(download),
                  child: Row(
                    children: [
                      if (widget.selectedIds.isNotEmpty)
                        Checkbox(
                          value: widget.selectedIds.contains(download.id),
                          onChanged: (_) => widget.onToggleSelection(download),
                        ),
                      Expanded(
                        child: isManga
                            ? CompletedDownloadChapterCard(
                                key: ValueKey(download.id),
                                item: download,
                                onOpen: () => widget.selectedIds.isNotEmpty
                                    ? widget.onToggleSelection(download)
                                    : _openMangaChapter(
                                        context,
                                        download,
                                        orderedItems,
                                      ),
                                onDelete: () => widget.selectedIds.isNotEmpty
                                    ? widget.onToggleSelection(download)
                                    : unawaited(
                                        confirmAndRemoveDownload(
                                          context,
                                          ref,
                                          download,
                                        ),
                                      ),
                              )
                            : CompletedDownloadEpisodeCard(
                                key: ValueKey(download.id),
                                item: download,
                                onPlay: () => widget.selectedIds.isNotEmpty
                                    ? widget.onToggleSelection(download)
                                    : _playLocalFile(
                                        context,
                                        ref,
                                        download,
                                        l10n,
                                      ),
                                onDelete: () => widget.selectedIds.isNotEmpty
                                    ? widget.onToggleSelection(download)
                                    : unawaited(
                                        confirmAndRemoveDownload(
                                          context,
                                          ref,
                                          download,
                                        ),
                                      ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!isLast)
                Divider(
                  height: 1,
                  indent: LayoutConstants.spacingMd,
                  endIndent: LayoutConstants.spacingMd,
                  color: theme.dividerColor.withValues(alpha: 0.4),
                ),
            ],
          );
        }).toList(),
      ),
    );
  }

  void _openMangaChapter(
    BuildContext context,
    DownloadItem item,
    List<DownloadItem> groupItems,
  ) {
    final chapter = item.chapter;
    if (chapter == null) return;
    final chapters = <MangaChapter>[
      for (final entry in groupItems)
        if (entry.chapter != null) entry.chapter!,
    ];
    MangaReaderRoute(
      $extra: MangaReaderRouteExtra(
        manga: item.item,
        chapter: chapter,
        chapters: chapters,
        localChapterDirectory: item.destinationPath,
      ),
    ).push<void>(context);
  }

  Future<void> _playLocalFile(
    BuildContext context,
    WidgetRef ref,
    DownloadItem item,
    AppLocalizations l10n,
  ) => ref
      .read(playbackLauncherProvider)
      .play(
        context,
        item.trackingUrl,
        baseItem: _savedPlaybackItem(item, items),
        episode: item.episode,
        resolveUrl: () => _resolveLocalPlaybackUrl(ref, item),
        onMissingFile: () => _removeMissingDownload(context, ref, item, l10n),
      );

  Future<void> _confirmDeleteAll(BuildContext context, WidgetRef ref) async {
    if (_deleteInFlight) return;
    setState(() => _deleteInFlight = true);
    final l10n = AppLocalizations.of(context)!;
    final selected = List<DownloadItem>.of(items);
    final notifications = ref.read(notificationServiceProvider);
    try {
      final confirmed = await showConfirmDialog(
        context,
        title: l10n.deleteAllEpisodes,
        message: l10n.confirmDeleteAllEpisodes(
          items.length,
          items.first.item.title,
        ),
        confirmLabel: l10n.deleteAll,
        cancelLabel: l10n.cancel,
      );
      if (!confirmed || !context.mounted) return;
      final removed = await ref
          .read(downloadsProvider.notifier)
          .removeDownloads(selected);
      if (!removed) {
        throw StateError('Unable to delete download while it is in use');
      }
    } catch (error) {
      showDownloadActionError(notifications, error);
    } finally {
      if (mounted) setState(() => _deleteInFlight = false);
    }
  }
}

class _DownloadItemTile extends ConsumerStatefulWidget {
  final DownloadItem item;
  final double progress;
  final TaskStatus status;
  final DownloadProgressData? progressData;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggleSelection;

  const _DownloadItemTile({
    super.key,
    required this.item,
    required this.progress,
    required this.status,
    this.progressData,
    required this.selecting,
    required this.selected,
    required this.onToggleSelection,
  });

  @override
  ConsumerState<_DownloadItemTile> createState() => _DownloadItemTileState();
}

class _DownloadItemTileState extends ConsumerState<_DownloadItemTile> {
  bool _controlInFlight = false;
  bool _deleteInFlight = false;

  DownloadItem get item => widget.item;
  double get progress => widget.progress;
  TaskStatus get status => widget.status;
  DownloadProgressData? get progressData => widget.progressData;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final chunkProgress = ref.watch(
      downloadChunkProgressProvider,
    )[item.task.taskId];
    final parallelParts = downloadTaskPartCount(item.task);
    final isDone = status == TaskStatus.complete;
    final isQueued = status == TaskStatus.enqueued;
    final isWorking =
        status == TaskStatus.running ||
        status == TaskStatus.enqueued ||
        status == TaskStatus.waitingToRetry;
    final isPaused = status == TaskStatus.paused;
    final isFailed =
        status == TaskStatus.failed || status == TaskStatus.notFound;

    final episodeLabel = item.episode == null
        ? null
        : formatEpisodeLabel(
            episode: item.episode!.episode,
            title: item.episode!.name,
            isFinal: item.episode!.isFinal,
            serverName: item.episode!.serverName,
          );
    final unitLabel = item.mediaKind == DownloadMediaKind.mangaChapter
        ? item.chapter?.name
        : episodeLabel;

    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(LayoutConstants.radiusMd),
      child: ArtworkDecode(
        paintedWidth: 80,
        builder: (BuildContext context, int? decodeWidth) => CachedNetworkImage(
          imageUrl: AppImageFallbacks.poster(item.item.posterUrl) ?? '',
          width: 80,
          height: 120,
          fit: BoxFit.cover,
          memCacheWidth: decodeWidth,
          filterQuality: FilterQuality.medium,
          errorWidget: (context, url, error) => Container(
            width: 80,
            height: 120,
            color: theme.dividerColor,
            child: const Icon(Icons.movie_outlined),
          ),
        ),
      ),
    );

    final content = Row(
      textDirection: TextDirection.ltr,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.selecting)
          Checkbox(
            value: widget.selected,
            onChanged: (_) => widget.onToggleSelection(),
          ),
        poster,
        const SizedBox(width: LayoutConstants.spacingMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.item.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (unitLabel != null) ...[
                const SizedBox(height: 2),
                Text(
                  unitLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(
                    isDone
                        ? Icons.check_circle_rounded
                        : isQueued
                        ? Icons.hourglass_top_rounded
                        : Icons.download_rounded,
                    size: 14,
                    color: isDone
                        ? Colors.green
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      isDone
                          ? l10n.completed
                          : _getStatusText(context, status, l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDone
                            ? Colors.green
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: LayoutConstants.spacingSm),
              if (!isDone) ...[
                Row(
                  textDirection: TextDirection.ltr,
                  children: [
                    Expanded(
                      child: Text(
                        _downloadedSizeText(context),
                        textDirection: TextDirection.ltr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.start,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: LayoutConstants.spacingSm),
                    Text(
                      parallelParts > 1
                          ? '$parallelParts×  ${(progress.clamp(0.0, 1.0) * 100).floor()}%'
                          : '${(progress.clamp(0.0, 1.0) * 100).floor()}%',
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SegmentedDownloadProgress(
                  task: item.task,
                  value: progress,
                  chunkProgress: chunkProgress,
                  backgroundColor: theme.dividerColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(LayoutConstants.radiusSm),
                ),
              ],
              if (!widget.selecting)
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (isWorking)
                      IconButton(
                        icon: const Icon(Icons.pause_rounded),
                        onPressed: _controlInFlight || _deleteInFlight
                            ? null
                            : _controlDownload,
                        visualDensity: VisualDensity.compact,
                      ),
                    if (isPaused || isFailed)
                      IconButton(
                        tooltip: isFailed
                            ? appText(
                                context,
                                english: 'Retry',
                                arabic: 'إعادة المحاولة',
                              )
                            : l10n.statusPaused,
                        icon: Icon(
                          isFailed
                              ? Icons.refresh_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        onPressed: _controlInFlight || _deleteInFlight
                            ? null
                            : _controlDownload,
                        visualDensity: VisualDensity.compact,
                      ),
                    if (isDone)
                      IconButton(
                        icon: const Icon(
                          Icons.play_circle_fill_rounded,
                          color: Colors.green,
                        ),
                        onPressed: () => _playLocalFile(context, ref, l10n),
                        iconSize: 28,
                      ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: _deleteInFlight ? null : _confirmDelete,
                      color: theme.colorScheme.error.withValues(alpha: 0.8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );

    final tile = InkWell(
      onLongPress: widget.onToggleSelection,
      onTap: widget.selecting
          ? widget.onToggleSelection
          : isDone
          ? () => _playLocalFile(context, ref, l10n)
          : null,
      borderRadius: BorderRadius.circular(LayoutConstants.radiusLg),
      child: content,
    );

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LayoutConstants.radiusXl),
        side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
      ),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(LayoutConstants.spacingMd),
        child: tile,
      ),
    );
  }

  Future<void> _controlDownload() async {
    if (_controlInFlight || _deleteInFlight) return;
    setState(() => _controlInFlight = true);
    final notifications = ref.read(notificationServiceProvider);
    try {
      await toggleDownloadPlayback(
        ref.read(downloadsProvider.notifier),
        item.task.taskId,
        status,
      );
    } catch (error) {
      showDownloadActionError(notifications, error);
    } finally {
      if (mounted) setState(() => _controlInFlight = false);
    }
  }

  String _downloadedSizeText(BuildContext context) {
    final data = progressData;
    if (item.mediaKind == DownloadMediaKind.mangaChapter) {
      return formatDownloadPageCount(
        completedPages: data?.completedPages ?? item.completedPages,
        totalPages: data?.totalPages ?? item.totalPages,
        pageLabel: appText(context, english: 'pages', arabic: 'صفحة'),
      );
    }
    return formatDownloadSizePair(
      totalBytes: data?.totalSize ?? -1,
      progress: progress,
    );
  }

  String _getStatusText(
    BuildContext context,
    TaskStatus status,
    AppLocalizations l10n,
  ) {
    switch (status) {
      case TaskStatus.enqueued:
        return l10n.statusQueued;
      case TaskStatus.running:
        return l10n.statusDownloading;
      case TaskStatus.complete:
        return l10n.statusFinished;
      case TaskStatus.failed:
      case TaskStatus.notFound:
        return appText(
          context,
          english: 'Download failed',
          arabic: 'فشل التنزيل',
        );
      case TaskStatus.paused:
        return l10n.statusPaused;
      case TaskStatus.canceled:
        return l10n.statusCanceled;
      case TaskStatus.waitingToRetry:
        return l10n.statusWaiting;
    }
  }

  Future<void> _playLocalFile(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) => ref
      .read(playbackLauncherProvider)
      .play(
        context,
        item.trackingUrl,
        baseItem: _savedPlaybackItem(
          item,
          ref.read(downloadsProvider).value ?? [item],
        ),
        episode: item.episode,
        resolveUrl: () => _resolveLocalPlaybackUrl(ref, item),
        onMissingFile: () => _removeMissingDownload(context, ref, item, l10n),
      );

  Future<void> _confirmDelete() async {
    if (_deleteInFlight) return;
    // A pending pause must never trap the user without a delete control.
    setState(() => _deleteInFlight = true);
    try {
      await confirmAndRemoveDownload(context, ref, item);
    } finally {
      if (mounted) setState(() => _deleteInFlight = false);
    }
  }
}
