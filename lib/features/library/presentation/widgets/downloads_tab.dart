import 'dart:async';

import '../../../../shared/widgets/confirm_dialog.dart';
import '../../../../shared/widgets/custom_widgets.dart';

import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show listEquals;
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
import 'segmented_download_progress.dart';
import 'completed_download_episode_card.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/localized_text.dart';
import '../../../details/presentation/downloaded_file_provider.dart';
import '../../../details/presentation/playback_launcher.dart';
import '../download_progress_v2_provider.dart';
import '../download_delete_confirmation.dart';
import '../downloads_provider.dart';
import '../../../../core/services/download_v2/download_v2_identity.dart';
import '../download_episode_artwork.dart';
import '../download_unit_count_label.dart';
import 'completed_download_chapter_card.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/utils/file_size_formatter.dart';
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
        sameDownloadProvider(download.item, selected.item) &&
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

bool _canPauseDownload(TaskStatus status) => switch (status) {
  TaskStatus.running ||
  TaskStatus.enqueued ||
  TaskStatus.waitingToRetry => true,
  _ => false,
};

class DownloadsTab extends ConsumerStatefulWidget {
  const DownloadsTab({super.key, this.headerPadding = EdgeInsets.zero});

  final EdgeInsetsGeometry headerPadding;

  @override
  ConsumerState<DownloadsTab> createState() => _DownloadsTabState();
}

class _DownloadsTabState extends ConsumerState<DownloadsTab>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin {
  late final TabController _tabs;
  final _selectionOverlay = OverlayPortalController();
  final Set<String> _selectedIds = <String>{};
  bool _bulkInFlight = false;
  int _tabIndex = 0;
  List<DownloadItem>? _uniqueDownloadRows;

  List<DownloadItem> _visibleRowsFor(List<DownloadItem> rows) {
    final previous = _uniqueDownloadRows;
    if (identical(previous, rows)) return rows;
    if (previous != null && previous.length == rows.length) {
      // With unique task IDs and one nonempty logical identity per row the
      // duplicate resolver cannot change visibility or order. A transfer tick
      // only replaces its own row. Keep fresh rows for controls and artwork.
      var sameIdentities = true;
      for (var i = 0; i < rows.length; i++) {
        if (!identical(rows[i], previous[i]) &&
            (rows[i].id != previous[i].id ||
                rows[i].logicalId != previous[i].logicalId)) {
          sameIdentities = false;
          break;
        }
      }
      if (sameIdentities) {
        _uniqueDownloadRows = rows;
        return rows;
      }
    }
    final visible = collapseDuplicateDownloads(rows).visible;
    final ids = <String>{};
    final unique =
        visible.length == rows.length &&
        rows.every(
          (row) => row.logicalId?.trim().isNotEmpty == true && ids.add(row.id),
        );
    _uniqueDownloadRows = unique ? rows : null;
    return unique ? rows : visible;
  }

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
            if (action == 'pause' && _canPauseDownload(item.status)) {
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
    _selectionOverlay.show();
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
        child: buildBatchSelectionDockFrame(
          colors: colors,
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
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.red.shade700,
                          disabledForegroundColor: Colors.white70,
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
    final l10n = AppLocalizations.of(context)!;

    // Keep local completed rows available through refreshes and transport errors.
    final visibleDownloads = _visibleRowsFor(
      downloadsAsync.hasValue
          ? downloadsAsync.value ?? const <DownloadItem>[]
          : const <DownloadItem>[],
    );
    final active = <DownloadItem>[];
    final completed = <DownloadItem>[];
    for (final item in visibleDownloads) {
      (isActiveDownloadStatus(item.status) ? active : completed).add(item);
    }
    final currentDownloads = _tabIndex == 0 ? active : completed;
    final selected = _selectedIds.isEmpty
        ? const <DownloadItem>[]
        : currentDownloads
              .where((item) => _selectedIds.contains(item.id))
              .toList();
    final currentSelectedIds = selected.isEmpty
        ? const <String>{}
        : selected.map((item) => item.id).toSet();
    final canPause = selected.any((item) => _canPauseDownload(item.status));
    final canResume = selected.any((item) => item.status == TaskStatus.paused);
    final controllableActive = active
        .where(
          (item) =>
              _canPauseDownload(item.status) ||
              item.status == TaskStatus.paused,
        )
        .toList();
    final allPaused =
        controllableActive.isNotEmpty &&
        controllableActive.every((item) => item.status == TaskStatus.paused);
    // RTL only for the tab strip + pager swipe (like المواسم). Each
    // pane is LTR so cards stay poster-left — do not mirror the page.
    final activePage = TickerMode.valuesOf(context).enabled;
    return OverlayPortal(
      overlayLocation: OverlayChildLocation.rootOverlay,
      controller: _selectionOverlay,
      overlayChildBuilder: (context) => selected.isEmpty || !activePage
          ? const SizedBox.shrink()
          : Positioned(
              left: 12,
              right: 12,
              bottom: 8,
              // Use device safe insets, without the shell's reserved dock space.
              child: MediaQuery.fromView(
                view: View.of(context),
                child: _buildSelectionBar(
                  selected: selected,
                  currentDownloads: currentDownloads,
                  canPause: canPause,
                  canResume: canResume,
                  l10n: l10n,
                ),
              ),
            ),
      child: Column(
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
          Expanded(
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: TabBarView(
                controller: _tabs,
                children: [
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Column(
                      children: [
                        const _DownloadSessionStrip(),
                        if (active.isNotEmpty && currentSelectedIds.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 6,
                            ),
                            child: Directionality(
                              textDirection: TextDirection.rtl,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      key: const ValueKey(
                                        'downloads-delete-all',
                                      ),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.red.shade700,
                                        foregroundColor: Colors.white,
                                        disabledBackgroundColor:
                                            Colors.red.shade700,
                                        disabledForegroundColor: Colors.white70,
                                      ),
                                      onPressed: _bulkInFlight
                                          ? null
                                          : () => _bulkAction(active, 'delete'),
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
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
                                      key: const ValueKey(
                                        'downloads-pause-resume-all',
                                      ),
                                      onPressed:
                                          _bulkInFlight ||
                                              controllableActive.isEmpty
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
                          child: downloadsAsync.when(
                            skipLoadingOnRefresh: false,
                            skipLoadingOnReload: false,
                            data: (_) => _ActiveDownloadsList(
                              items: active,
                              emptyMessage: l10n.noDownloadsYet,
                              selectedIds: currentSelectedIds,
                              onToggleSelection: _toggleSelected,
                            ),
                            loading: () =>
                                const Center(child: AppLoadingIndicator()),
                            error: (err, stack) => Center(
                              child: Text(l10n.errorPrefix(err.toString())),
                            ),
                          ),
                        ),
                      ],
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
          // Reserve room so the last download can scroll clear of the controls.
          if (selected.isNotEmpty) const SizedBox(height: 148),
        ],
      ),
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
    required this.emptyMessage,
    required this.selectedIds,
    required this.onToggleSelection,
  });

  final List<DownloadItem> items;
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
          return _ActiveDownloadRow(
            key: ValueKey(download.id),
            item: download,
            selecting: selectedIds.isNotEmpty,
            selected: selectedIds.contains(download.id),
            onToggleSelection: onToggleSelection,
          );
        },
      ),
    );
  }
}

// A transfer update replaces only the changed DownloadItem. Keep unaffected
// mounted rows' tile configurations stable; each tile still watches its own
// projected progress and inherited settings independently.
class _ActiveDownloadRow extends StatefulWidget {
  const _ActiveDownloadRow({
    super.key,
    required this.item,
    required this.selecting,
    required this.selected,
    required this.onToggleSelection,
  });

  final DownloadItem item;
  final bool selecting;
  final bool selected;
  final ValueChanged<DownloadItem> onToggleSelection;

  @override
  State<_ActiveDownloadRow> createState() => _ActiveDownloadRowState();
}

class _ActiveDownloadRowState extends State<_ActiveDownloadRow> {
  late Widget _tile = _buildTile();

  @override
  void didUpdateWidget(covariant _ActiveDownloadRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.item, widget.item) ||
        oldWidget.selecting != widget.selecting ||
        oldWidget.selected != widget.selected) {
      _tile = _buildTile();
    }
  }

  Widget _buildTile() => _DownloadItemTile(
    item: widget.item,
    selecting: widget.selecting,
    selected: widget.selected,
    onToggleSelection: _toggleSelection,
  );

  void _toggleSelection() => widget.onToggleSelection(widget.item);

  @override
  Widget build(BuildContext context) => _tile;
}

class _CompletedDownloadsList extends StatefulWidget {
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
  State<_CompletedDownloadsList> createState() =>
      _CompletedDownloadsListState();
}

class _CompletedDownloadsListState extends State<_CompletedDownloadsList> {
  late List<MapEntry<String, List<DownloadItem>>> _groups;

  @override
  void initState() {
    super.initState();
    _groupRows();
  }

  @override
  void didUpdateWidget(covariant _CompletedDownloadsList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Committed rows keep their identity on another transfer's progress tick.
    // Rebuild the groups only for a genuinely new completed snapshot.
    if (!listEquals(oldWidget.items, widget.items)) _groupRows();
  }

  void _groupRows() {
    final grouped = <String, List<DownloadItem>>{};
    for (final item in widget.items) {
      final mediaIdentity =
          item.item.tmdbId?.toString() ??
          (item.item.url.trim().isNotEmpty
              ? item.item.url.trim()
              : item.item.title);
      final source = item.mediaKind == DownloadMediaKind.videoEpisode
          ? downloadProviderScopeV2(item.item.provider) ?? ''
          : '';
      final key = '${item.mediaKind.name}:$source:$mediaIdentity';
      grouped.putIfAbsent(key, () => []).add(item);
    }
    _groups = grouped.entries.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    if (_groups.isEmpty) {
      return _DownloadsEmptyState(message: widget.emptyMessage);
    }
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        itemCount: _groups.length,
        separatorBuilder: (context, index) => const SizedBox(height: 16),
        itemBuilder: (context, index) {
          final group = _groups[index];
          return _GroupedDownloadTile(
            key: ValueKey(group.key),
            items: group.value,
            selectedIds: widget.selectedIds,
            onToggleSelection: widget.onToggleSelection,
            onToggleGroupSelection: widget.onToggleGroupSelection,
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
  late Future<bool> _showNetworkFallback;
  Widget? _posterWidget;
  (String?, Color)? _posterInputs;
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
    _startPosterLookup();
  }

  @override
  void didUpdateWidget(covariant _GroupedDownloadTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.items, items) &&
        _posterKey(oldWidget.items) != _posterKey(items)) {
      _startPosterLookup();
    }
  }

  void _startPosterLookup() {
    _posterWidget = null;
    final input = items;
    final local = _findLocalPoster(input);
    _poster = local.then((saved) => saved ?? _restorePoster(input));
    // A retained poster should not start a second disk/network image decode.
    // Bound the grace period so slow storage or a very large group cannot hold
    // up the ordinary remote fallback.
    _showNetworkFallback =
        AppImageFallbacks.poster(input.first.item.posterUrl) == null
        ? Future.value(false)
        : local
              .then((saved) => saved == null)
              .timeout(const Duration(milliseconds: 60), onTimeout: () => true);
  }

  Future<File?> _findLocalPoster(List<DownloadItem> input) async {
    // A group's first row may lack artwork while another retained copy exists.
    for (final item in input) {
      final saved = await existingDownloadedPosterArtwork(_artworkId(item));
      if (saved != null) return saved;
    }
    return null;
  }

  Future<File?> _restorePoster(List<DownloadItem> input) async {
    for (final item in input) {
      if (!item.artworkMetadataVerified) continue;
      final saved = await ensureDownloadedPosterArtwork(
        logicalId: _artworkId(item),
        posterUrl: item.item.posterUrl,
      );
      if (saved != null) return saved;
    }
    return null;
  }

  Widget _posterFor(String? rawUrl, Color dividerColor) {
    final inputs = (rawUrl, dividerColor);
    final previous = _posterWidget;
    if (previous != null && _posterInputs == inputs) return previous;
    _posterInputs = inputs;

    Widget placeholder() => Container(
      width: 80,
      height: 120,
      color: dividerColor,
      child: const Icon(Icons.movie_outlined),
    );

    final url = AppImageFallbacks.poster(rawUrl);
    final poster = _poster;
    final showNetworkFallback = _showNetworkFallback;
    // Keep the mounted image builders out of selection and transfer updates.
    // ArtworkDecode still owns its quality and device pixel ratio dependencies.
    return _posterWidget = ClipRRect(
      borderRadius: BorderRadius.circular(LayoutConstants.radiusMd),
      child: ArtworkDecode(
        paintedWidth: 80,
        sizeHighQualityToDisplay: true,
        builder: (BuildContext context, int? decodeWidth) =>
            FutureBuilder<File?>(
              key: ObjectKey(poster),
              future: poster,
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
                    errorBuilder: (_, _, _) => placeholder(),
                  );
                }
                if (url == null) return placeholder();
                return FutureBuilder<bool>(
                  future: showNetworkFallback,
                  builder: (context, fallback) => fallback.data != true
                      ? placeholder()
                      : CachedNetworkImage(
                          imageUrl: url,
                          width: 80,
                          height: 120,
                          fit: BoxFit.cover,
                          memCacheWidth: decodeWidth,
                          filterQuality: FilterQuality.medium,
                          errorWidget: (_, _, _) => placeholder(),
                        ),
                );
              },
            ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final firstItem = items.first;
    final selecting = widget.selectedIds.isNotEmpty;
    final anySelected = items.any(
      (item) => widget.selectedIds.contains(item.id),
    );
    final allSelected = items.every(
      (item) => widget.selectedIds.contains(item.id),
    );
    final isManga = firstItem.mediaKind == DownloadMediaKind.mangaChapter;

    return Card(
      margin: EdgeInsets.zero,
      color: anySelected
          ? theme.colorScheme.primary.withValues(alpha: 0.24)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LayoutConstants.radiusXl),
        side: BorderSide(
          color: anySelected
              ? theme.colorScheme.primary
              : theme.dividerColor.withValues(alpha: 0.5),
          width: anySelected ? 2 : 1,
        ),
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
              _posterFor(firstItem.item.posterUrl, theme.dividerColor),
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
                icon: Icon(
                  selecting
                      ? allSelected
                            ? Icons.check_circle_rounded
                            : anySelected
                            ? Icons.remove_circle_outline_rounded
                            : Icons.radio_button_unchecked_rounded
                      : Icons.delete_outline_rounded,
                ),
                onPressed: widget.selectedIds.isNotEmpty
                    ? () => widget.onToggleGroupSelection(items)
                    : _deleteInFlight
                    ? null
                    : () => _confirmDeleteAll(context, ref),
                color: selecting
                    ? theme.colorScheme.primary
                    : theme.colorScheme.error.withValues(alpha: 0.8),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        children: [
          _CompletedDownloadRows(
            items: items,
            isManga: isManga,
            builder: (context, ref, orderedItems) => _buildDownloadRows(
              context,
              ref,
              orderedItems,
              isManga: isManga,
              selecting: selecting,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadRows(
    BuildContext context,
    WidgetRef ref,
    List<DownloadItem> orderedItems, {
    required bool isManga,
    required bool selecting,
  }) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Column(
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
                child: isManga
                    ? CompletedDownloadChapterCard(
                        key: ValueKey(download.id),
                        item: download,
                        selecting: selecting,
                        selected: widget.selectedIds.contains(download.id),
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
                        selecting: selecting,
                        selected: widget.selectedIds.contains(download.id),
                        onPlay: () => widget.selectedIds.isNotEmpty
                            ? widget.onToggleSelection(download)
                            : _playLocalFile(context, ref, download, l10n),
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
  ) {
    final groupItems = items;
    return ref
        .read(playbackLauncherProvider)
        .playDownloaded(
          context,
          item.trackingUrl,
          prepareBaseItem: () => _savedPlaybackItem(item, groupItems),
          episode: item.episode,
          resolveUrl: () => _resolveLocalPlaybackUrl(ref, item),
          onMissingFile: () => _removeMissingDownload(context, ref, item, l10n),
        );
  }

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

// ExpansionTile only mounts this projection while the group is open.
// Selection and active-transfer updates do not change the completed rows
// or their order. Keep the same projection until either one changes.
class _CompletedDownloadRows extends ConsumerStatefulWidget {
  const _CompletedDownloadRows({
    required this.items,
    required this.isManga,
    required this.builder,
  });

  final List<DownloadItem> items;
  final bool isManga;
  final Widget Function(BuildContext, WidgetRef, List<DownloadItem>) builder;

  @override
  ConsumerState<_CompletedDownloadRows> createState() =>
      _CompletedDownloadRowsState();
}

class _CompletedDownloadRowsState
    extends ConsumerState<_CompletedDownloadRows> {
  List<DownloadItem>? _input;
  late List<DownloadItem> _ordered;
  late bool _ascending;
  late bool _isManga;

  @override
  Widget build(BuildContext context) {
    final ascending = ref.watch(episodeSortAscendingProvider);
    final items = widget.items;
    final isManga = widget.isManga;
    if (!identical(_input, items) ||
        _ascending != ascending ||
        _isManga != isManga) {
      _ordered = _orderRows(items, isManga: isManga, ascending: ascending);
      _input = items;
      _ascending = ascending;
      _isManga = isManga;
    }
    return widget.builder(context, ref, _ordered);
  }

  List<DownloadItem> _orderRows(
    List<DownloadItem> items, {
    required bool isManga,
    required bool ascending,
  }) {
    return isManga
        ? (List<DownloadItem>.from(items)..sort((a, b) {
            final an = a.chapter?.number;
            final bn = b.chapter?.number;
            if (an != null && bn != null) {
              final compare = an.compareTo(bn);
              if (compare != 0) {
                return ascending ? compare : -compare;
              }
            }
            final compare = (a.chapter?.name ?? '').compareTo(
              b.chapter?.name ?? '',
            );
            return ascending ? compare : -compare;
          }))
        : episodeItemsInDisplayOrder(
            items,
            episodeOf: (item) => item.episode,
            ascending: ascending,
          );
  }
}

class _DownloadItemTile extends ConsumerStatefulWidget {
  final DownloadItem item;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggleSelection;

  const _DownloadItemTile({
    required this.item,
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

  (String, Color)? _posterInputs;
  Widget? _posterWidget;

  Widget _posterFor(String url, Color errorColor) {
    final inputs = (url, errorColor);
    final previous = _posterWidget;
    if (previous != null && _posterInputs == inputs) return previous;
    _posterInputs = inputs;
    // Keep stable art out of transfer ticks. The mounted ArtworkDecode still
    // handles quality and device-scale changes itself.
    return _posterWidget = ClipRRect(
      borderRadius: BorderRadius.circular(LayoutConstants.radiusMd),
      child: ArtworkDecode(
        paintedWidth: 80,
        sizeHighQualityToDisplay: true,
        builder: (BuildContext context, int? decodeWidth) => CachedNetworkImage(
          imageUrl: url,
          width: 80,
          height: 120,
          fit: BoxFit.cover,
          memCacheWidth: decodeWidth,
          filterQuality: FilterQuality.medium,
          errorWidget: (context, url, error) => Container(
            width: 80,
            height: 120,
            color: errorColor,
            child: const Icon(Icons.movie_outlined),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final logicalId = item.logicalId?.trim();
    final progressKey = logicalId?.isNotEmpty == true
        ? logicalId!
        : item.task.metaData.isNotEmpty
        ? item.task.metaData
        : item.task.url;
    final progressData = ref.watch(
      downloadProgressProvider.select((rows) {
        final data = rows[progressKey];
        // The shared projection allocates the data object on every emission.
        // Compare only what this row actually uses.
        return data == null
            ? null
            : (
                data.progress,
                data.status,
                data.totalSize,
                data.completedPages,
                data.totalPages,
              );
      }),
    );
    final progress = progressData?.$1 ?? item.progress;
    final status = progressData?.$2 ?? item.status;
    final chunkProgress = ref.watch(
      downloadChunkProgressProvider,
    )[item.task.taskId];
    final isDone = status == TaskStatus.complete;
    final isQueued = status == TaskStatus.enqueued;
    final isWorking = _canPauseDownload(status);
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

    final poster = _posterFor(
      AppImageFallbacks.poster(item.item.posterUrl) ?? '',
      theme.dividerColor,
    );

    final content = Row(
      textDirection: TextDirection.ltr,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                        _downloadedSizeText(
                          context,
                          progress,
                          progressData?.$3,
                          progressData?.$4,
                          progressData?.$5,
                        ),
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
                      '${item.activeConnections}×  ${(progress.clamp(0.0, 1.0) * 100).floor()}%',
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
              if (widget.selecting)
                Align(
                  alignment: Alignment.centerRight,
                  child: Icon(
                    widget.selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: theme.colorScheme.primary,
                    size: 30,
                  ),
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (isWorking)
                      IconButton(
                        icon: const Icon(Icons.pause_rounded),
                        onPressed: _controlInFlight || _deleteInFlight
                            ? null
                            : () => _controlDownload(status),
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
                            : () => _controlDownload(status),
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
        side: BorderSide(
          color: widget.selected
              ? theme.colorScheme.primary
              : theme.dividerColor.withValues(alpha: 0.5),
          width: widget.selected ? 2 : 1,
        ),
      ),
      color: widget.selected
          ? theme.colorScheme.primary.withValues(alpha: 0.24)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(LayoutConstants.spacingMd),
        child: tile,
      ),
    );
  }

  Future<void> _controlDownload(TaskStatus status) async {
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

  String _downloadedSizeText(
    BuildContext context,
    double progress,
    int? totalBytes,
    int? completedPages,
    int? totalPages,
  ) {
    if (item.mediaKind == DownloadMediaKind.mangaChapter) {
      return formatDownloadPageCount(
        completedPages: completedPages ?? item.completedPages,
        totalPages: totalPages ?? item.totalPages,
        pageLabel: appText(context, english: 'pages', arabic: 'صفحة'),
      );
    }
    return formatDownloadSizePair(
      totalBytes: totalBytes ?? -1,
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
  ) {
    final selected = item;
    return ref
        .read(playbackLauncherProvider)
        .playDownloaded(
          context,
          selected.trackingUrl,
          prepareBaseItem: () => _savedPlaybackItem(
            selected,
            ref.read(downloadsProvider).value ?? [selected],
          ),
          episode: selected.episode,
          resolveUrl: () => _resolveLocalPlaybackUrl(ref, item),
          onMissingFile: () => _removeMissingDownload(context, ref, item, l10n),
        );
  }

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
