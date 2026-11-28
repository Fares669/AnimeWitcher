import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/providers/episode_sort_provider.dart';
import '../../../../core/services/download_v2/download_v2_identity.dart';
import '../../../../core/services/download_v2/download_v2_models.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/storage/manga_reading_repository.dart';
import '../../../../core/utils/download_progress_data.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import '../../../details/presentation/widgets/details_hero_actions.dart';
import '../../../details/presentation/widgets/details_layout_widgets.dart'
    show buildDetailsSortToggle;
import '../../../details/presentation/widgets/download_progress_dialog.dart';
import '../../../details/presentation/widgets/episode_action_chip.dart';
import '../../../library/presentation/download_progress_v2_provider.dart';
import '../../../library/presentation/downloads_provider.dart';
import 'manga_chapter_browse.dart';
import 'manga_chapter_download_index.dart';
import 'manga_chapter_row.dart';

class MangaChapterSortButton extends ConsumerWidget {
  const MangaChapterSortButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ascending = ref.watch(episodeSortAscendingProvider);
    return buildDetailsSortToggle(
      context,
      ascending: ascending,
      inkWellKey: const ValueKey<String>('manga-chapter-sort-toggle'),
      onTap: () => ref
          .read(episodeSortAscendingProvider.notifier)
          .setAscending(!ascending),
    );
  }
}

class MangaChapterList extends ConsumerStatefulWidget {
  const MangaChapterList({
    super.key,
    required this.chapters,
    this.onOpen,
    this.onDownload,
    this.onDownloadSelected,
    this.downloads = const <DownloadItem>[],
    this.onDeleteDownload,
    this.embedded = false,
    this.onSelectionBarChanged,
    this.topAction,
    this.transition,
    this.revealKey,
  });

  /// A published chapter snapshot. Supply a new list when it changes.
  final List<MangaChapter> chapters;
  final ValueChanged<MangaChapter>? onOpen;
  final ValueChanged<MangaChapter>? onDownload;
  final Future<int> Function(List<MangaChapter>)? onDownloadSelected;
  final List<DownloadItem> downloads;
  final ValueChanged<DownloadItem>? onDeleteDownload;
  final ValueChanged<Widget?>? onSelectionBarChanged;
  final Widget? topAction;
  final Animation<double>? transition;
  final Key? revealKey;

  /// Laid out as part of a longer page that does the scrolling — the wide
  /// details layout, where the chapters follow the synopsis the way the
  /// episodes do for an anime — rather than as a list of its own. The list
  /// is then a sliver, for that page's [CustomScrollView].
  final bool embedded;

  @override
  ConsumerState<MangaChapterList> createState() => _MangaChapterListState();
}

class _MangaChapterListState extends ConsumerState<MangaChapterList> {
  final Set<String> _selectedChapterIds = <String>{};
  List<DownloadItem>? _indexedDownloads;
  List<DownloadItem> _completedRows = const <DownloadItem>[];
  late MangaChapterDownloadIndex _completedIndex = MangaChapterDownloadIndex(
    _completedRows,
  );
  List<List<MangaChapter>>? _ranges;
  ({int index, List<MangaChapter> chapters})? _rangeMembers;
  ({int? range, String query, List<MangaChapter> chapters})? _narrowed;

  List<List<MangaChapter>> get _chapterRanges =>
      _ranges ??= mangaChapterRanges(widget.chapters);

  List<MangaChapter> _membersForRange(int range) {
    final previous = _rangeMembers;
    if (previous != null && previous.index == range) return previous.chapters;
    final allowedIds = _chapterRanges[range]
        .map((chapter) => chapter.id)
        .toSet();
    // The menu groups use reading order, but the list has always displayed
    // membership in source order (including any repeated chapter IDs).
    final chapters = <MangaChapter>[
      for (final chapter in widget.chapters)
        if (allowedIds.contains(chapter.id)) chapter,
    ];
    _rangeMembers = (index: range, chapters: chapters);
    return chapters;
  }

  List<MangaChapter> _chaptersForRangeAndQuery(int? range) {
    if (range == null) _rangeMembers = null;
    final query = _query.trim();
    if (range == null && query.isEmpty) {
      _narrowed = null;
      return widget.chapters;
    }
    final previous = _narrowed;
    if (previous != null &&
        previous.range == range &&
        previous.query == query) {
      return previous.chapters;
    }
    final candidates = range == null
        ? widget.chapters
        : _membersForRange(range);
    final chapters = query.isEmpty
        ? candidates
        : candidates.where(mangaChapterMatcher(query)).toList(growable: false);
    _narrowed = (range: range, query: query, chapters: chapters);
    return chapters;
  }

  MangaChapterDownloadIndex get _completedDownloads {
    final downloads = widget.downloads;
    if (identical(downloads, _indexedDownloads)) return _completedIndex;

    // Transport ticks publish a new list but reuse unchanged download rows.
    // Compare only the complete Manga rows in source order; that order
    // decides which record owns an alias. Don't allocate another list or
    // rebuild the alias tables when that subsequence hasn't changed.
    List<DownloadItem>? changed;
    var count = 0;
    for (final item in downloads) {
      if (item.mediaKind != DownloadMediaKind.mangaChapter ||
          item.status != TaskStatus.complete) {
        continue;
      }
      if (changed != null) {
        changed.add(item);
      } else if (count >= _completedRows.length ||
          !identical(_completedRows[count], item)) {
        changed = <DownloadItem>[..._completedRows.take(count), item];
      }
      count++;
    }
    if (changed != null || count != _completedRows.length) {
      _completedRows = changed ?? _completedRows.take(count).toList();
      _completedIndex = MangaChapterDownloadIndex(_completedRows);
    }
    _indexedDownloads = downloads;
    return _completedIndex;
  }

  Widget _withTransition(Widget child, {Key? key}) {
    final animation = widget.transition;
    if (animation == null) return child;
    return FadeTransition(
      key: key,
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.045),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  }

  /// The range menu's pick; null shows every chapter, which is the default.
  int? _rangeIndex;
  MangaChapterFilter _filter = MangaChapterFilter.all;
  String _query = '';
  final TextEditingController _goToController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Animation<double>? _routeSecondaryAnimation;
  AnimationStatusListener? _routeStatusListener;

  bool get _selecting => _selectedChapterIds.isNotEmpty;

  @override
  void didUpdateWidget(covariant MangaChapterList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chapters, widget.chapters)) {
      _ranges = null;
      _rangeMembers = null;
      _narrowed = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.secondaryAnimation;
    if (identical(animation, _routeSecondaryAnimation)) return;

    final oldListener = _routeStatusListener;
    if (oldListener != null) {
      _routeSecondaryAnimation?.removeStatusListener(oldListener);
    }

    _routeSecondaryAnimation = animation;
    _routeStatusListener = (status) {
      if (status == AnimationStatus.forward && mounted && _selecting) {
        _clearSelection();
      }
    };
    final listener = _routeStatusListener;
    if (animation != null && listener != null) {
      animation.addStatusListener(listener);
    }
  }

  @override
  void dispose() {
    final listener = _routeStatusListener;
    if (listener != null) {
      _routeSecondaryAnimation?.removeStatusListener(listener);
    }
    _goToController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// The search narrows the list as it is typed, as the anime episode
  /// search does, rather than jumping to one chapter.
  void _search(String raw) => setState(() => _query = raw);

  DownloadProgressData? _progressFor(
    MangaChapter chapter,
    Map<String, DownloadProgressData> progressById,
  ) {
    if (progressById.isEmpty) return null;
    DownloadProgressData? data;
    final mangaId = chapter.mangaId.trim();
    if (mangaId.isNotEmpty && chapter.id.trim().isNotEmpty) {
      data =
          progressById[logicalDownloadIdForMangaChapter(
            mangaId: mangaId,
            chapterId: chapter.id,
          ).value];
    }
    return data ?? progressById[chapter.url];
  }

  bool _isDownloaded(
    MangaChapter chapter,
    Map<String, DownloadProgressData> progressById,
  ) =>
      _completedDownloads.completed(chapter) != null ||
      _progressFor(chapter, progressById)?.status == TaskStatus.complete;

  /// The range menu: every chapter, or one run of fifty, each with how many
  /// of it are read.
  Widget _rangeMenu(
    BuildContext context,
    int? range,
    MangaReadingRepository repository,
  ) {
    final colors = Theme.of(context).colorScheme;
    const all = 'كل الفصول';
    String rangeTitle(List<MangaChapter> chapters, int index) =>
        'الفصول ${mangaChapterRangeLabel(chapters, index)}';
    return PopupMenuButton<int>(
      key: const ValueKey<String>('manga-chapter-range-menu'),
      tooltip: 'نطاق الفصول',
      initialValue: range ?? -1,
      onSelected: (value) =>
          setState(() => _rangeIndex = value < 0 ? null : value),
      itemBuilder: (_) {
        // Hundreds of off-screen rows may arrive at once. Build the
        // reading-order groups only when this menu or a selection needs them.
        final ranges = _chapterRanges;
        return <PopupMenuEntry<int>>[
          const PopupMenuItem<int>(value: -1, child: Text(all)),
          for (var i = 0; i < ranges.length; i++)
            PopupMenuItem<int>(
              value: i,
              child: Row(
                children: <Widget>[
                  Expanded(child: Text(rangeTitle(ranges[i], i))),
                  const SizedBox(width: 16),
                  Text(
                    () {
                      final read = ranges[i]
                          .where(
                            (c) =>
                                repository.get(c.mangaId, c.id)?.isRead == true,
                          )
                          .length;
                      if (read == ranges[i].length) {
                        return 'مكتمل';
                      }
                      return '$read/${ranges[i].length}';
                    }(),
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
        ];
      },
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: colors.onSurfaceVariant.withValues(alpha: 0.16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              range == null ? all : rangeTitle(_chapterRanges[range], range),
              style: TextStyle(color: colors.onSurface, fontSize: 13),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: colors.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _goToField(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 190,
      height: 40,
      child: TextField(
        key: const ValueKey<String>('manga-chapter-go-to'),
        controller: _goToController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.go,
        onChanged: _search,
        onSubmitted: _search,
        style: TextStyle(color: colors.onSurface, fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'ابحث عن فصل…',
          hintStyle: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 18,
            color: colors.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          filled: true,
          fillColor: kDetailsHeroGlassFallback,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(
              color: colors.onSurfaceVariant.withValues(alpha: 0.16),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(
              color: colors.onSurfaceVariant.withValues(alpha: 0.16),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide(color: colors.primary),
          ),
        ),
      ),
    );
  }

  Widget _filterChips(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labels = <MangaChapterFilter, String>{
      MangaChapterFilter.all: 'الكل',
      MangaChapterFilter.unread: 'غير المقروءة',
      MangaChapterFilter.downloaded: 'المنزّلة',
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final entry in labels.entries)
                ChoiceChip(
                  key: ValueKey<String>(
                    'manga-chapter-filter-${entry.key.name}',
                  ),
                  label: Text(entry.value),
                  selected: _filter == entry.key,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _filter = entry.key),
                  labelStyle: TextStyle(
                    fontSize: 13,
                    color: _filter == entry.key
                        ? colors.primary
                        : colors.onSurface,
                  ),
                  side: BorderSide(
                    color: _filter == entry.key
                        ? colors.primary
                        : colors.onSurfaceVariant.withValues(alpha: 0.16),
                  ),
                  shape: const StadiumBorder(),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const MangaChapterSortButton(),
      ],
    );
  }

  /// Range and search tools, with reading-state filters below them.
  Widget _toolbar(
    BuildContext context, {
    required int rangeCount,
    required int? range,
    required MangaReadingRepository repository,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (rangeCount > 1) _rangeMenu(context, range, repository),
            _goToField(context),
          ],
        ),
        const SizedBox(height: 10),
        _filterChips(context),
        if (widget.topAction != null) ...<Widget>[
          const SizedBox(height: 10),
          widget.topAction!,
        ],
      ],
    );
  }

  void _syncSelectionSurface() {
    if (!widget.embedded || !mounted) return;
    widget.onSelectionBarChanged?.call(
      _selecting ? _selectionBar(context) : null,
    );
  }

  void _toggleSelection(MangaChapter chapter) {
    setState(() {
      if (!_selectedChapterIds.add(chapter.id)) {
        _selectedChapterIds.remove(chapter.id);
      }
    });
    _syncSelectionSurface();
  }

  void _beginSelection(MangaChapter chapter) {
    setState(() => _selectedChapterIds.add(chapter.id));
    _syncSelectionSurface();
  }

  void _clearSelection() {
    if (!_selecting) return;
    setState(_selectedChapterIds.clear);
    _syncSelectionSurface();
  }

  void _selectAll() {
    setState(() {
      _selectedChapterIds
        ..clear()
        ..addAll(widget.chapters.map((chapter) => chapter.id));
    });
    _syncSelectionSurface();
  }

  Future<void> _setSelectedRead(bool read) async {
    final repository = ref.read(mangaReadingRepositoryProvider);
    final selected = widget.chapters
        .where((chapter) => _selectedChapterIds.contains(chapter.id))
        .toList(growable: false);
    final byManga = <String, List<String>>{};
    for (final chapter in selected) {
      final mangaId = chapter.mangaId.trim();
      if (mangaId.isEmpty) continue;
      byManga.putIfAbsent(mangaId, () => <String>[]).add(chapter.id);
    }

    // Match Anime selection UX: close the selection surface immediately.
    _clearSelection();

    for (final entry in byManga.entries) {
      await repository.setReadStates(entry.key, entry.value, read: read);
    }
  }

  Future<void> _downloadSelected() async {
    final action = widget.onDownloadSelected;
    if (action == null) return;
    final selected = widget.chapters
        .where((chapter) => _selectedChapterIds.contains(chapter.id))
        .toList();
    // Batch add also needs active and paused records, unlike row actions.
    // Use the current snapshot at the time of this user action.
    final existing = MangaChapterDownloadIndex(widget.downloads);
    final chapters = selected
        .where((chapter) => !existing.alreadyPresent(chapter))
        .toList();
    final skipped = selected.length - chapters.length;
    chapters.sort((a, b) {
      if (a.number != null && b.number == null) return -1;
      if (a.number == null && b.number != null) return 1;
      if (a.number != null && b.number != null) {
        final result = a.number!.compareTo(b.number!);
        if (result != 0) return result;
      }
      return a.displayName.compareTo(b.displayName);
    });
    _clearSelection();
    var failed = 0;
    if (chapters.isNotEmpty) {
      try {
        failed = await action(chapters);
      } catch (_) {
        failed = chapters.length;
      }
    }
    if (!mounted) return;
    final added = chapters.length - failed;
    final message =
        'تمت إضافة $added فصل، وتم تجاوز $skipped'
        '${failed > 0 ? '، وفشل $failed' : ''}';
    final notifications = ref.read(notificationServiceProvider);
    if (failed > 0) {
      notifications.showError(message);
    } else {
      notifications.showSuccess(message);
    }
  }

  Widget _selectionBar(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final count = _selectedChapterIds.length;
    final selectedLabel = 'تم تحديد $count';

    Widget actionButton({
      required String label,
      required IconData icon,
      required VoidCallback onPressed,
      required bool outlined,
    }) {
      if (outlined) {
        return OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 21),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            visualDensity: VisualDensity.compact,
          ),
        );
      }
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 21),
        label: Text(label),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: buildBatchSelectionDockFrame(
          colors: colors,
          child: SizedBox(
            height: widget.onDownloadSelected == null ? 120 : 168,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.checklist_rounded,
                        color: colors.primary,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          selectedLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'إلغاء التحديد',
                        visualDensity: VisualDensity.compact,
                        onPressed: _clearSelection,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  if (widget.onDownloadSelected != null) ...[
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      height: 42,
                      child: FilledButton.icon(
                        key: const ValueKey('batch-download-chapters'),
                        onPressed: _downloadSelected,
                        icon: const Icon(Icons.download_rounded),
                        label: Text('تنزيل $count فصل'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: actionButton(
                          label: 'تمت قراءته',
                          icon: Icons.visibility_rounded,
                          outlined: false,
                          onPressed: () => _setSelectedRead(true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: actionButton(
                          label: 'غير مقروء',
                          icon: Icons.visibility_off_rounded,
                          outlined: true,
                          onPressed: () => _setSelectedRead(false),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: 'تحديد جميع الفصول',
                        onPressed: _selectAll,
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
      ),
    );
  }

  Widget? _downloadAction(
    BuildContext context,
    MangaChapter chapter,
    Map<String, DownloadProgressData> progressById,
  ) {
    if (widget.onDownload == null) return null;
    DownloadProgressData? data;
    var progressIdentity = chapter.url;
    final mangaId = chapter.mangaId.trim();
    if (progressById.isNotEmpty &&
        mangaId.isNotEmpty &&
        chapter.id.trim().isNotEmpty) {
      final logicalId = logicalDownloadIdForMangaChapter(
        mangaId: mangaId,
        chapterId: chapter.id,
      ).value;
      data = progressById[logicalId];
      if (data != null) progressIdentity = logicalId;
    }
    data ??= progressById[chapter.url];

    final completedDownload = _completedDownloads.completed(chapter);
    final status = data?.status;
    final active =
        status == TaskStatus.running ||
        status == TaskStatus.enqueued ||
        status == TaskStatus.waitingToRetry ||
        status == TaskStatus.paused;

    if (completedDownload != null || status == TaskStatus.complete) {
      return EpisodeActionChip(
        tooltip: AppLocalizations.of(context)?.deleteDownload ?? 'حذف الفصل',
        onPressed: completedDownload != null && widget.onDeleteDownload != null
            ? () => widget.onDeleteDownload!(completedDownload)
            : () {},
        icon: Icons.delete_outline_rounded,
        color: Theme.of(context).colorScheme.error,
      );
    }

    if (data != null && active) {
      void showProgress() => DownloadProgressDialog.show(
        context,
        chapter.displayName,
        progressIdentity,
      );

      if (status == TaskStatus.paused) {
        return EpisodeActionChip(
          tooltip: 'التنزيل متوقف مؤقتًا',
          onPressed: showProgress,
          child: Icon(
            Icons.pause_rounded,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
        );
      }
      final value = data.progress.clamp(0.0, 1.0);
      return EpisodeActionChip(
        tooltip: 'جارٍ تنزيل الفصل',
        onPressed: showProgress,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              CircularProgressIndicator(
                value: value > 0 ? value : null,
                strokeWidth: 2,
              ),
              Text(
                '${(value * 100).floor()}%',
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return EpisodeActionChip(
      tooltip:
          AppLocalizations.of(context)?.mangaDownloadChapter ?? 'تنزيل الفصل',
      onPressed: () => widget.onDownload!(chapter),
      icon: Icons.save_alt_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(mangaReadingRevisionProvider);
    final repository = ref.watch(mangaReadingRepositoryProvider);
    final progressById = ref.watch(downloadProgressProvider);
    final l10n = AppLocalizations.of(context);

    final ascending = ref.watch(episodeSortAscendingProvider);

    if (widget.chapters.isEmpty) {
      final note = Center(child: Text(l10n?.mangaNoChapters ?? 'لا توجد فصول'));
      return widget.embedded ? SliverToBoxAdapter(child: note) : note;
    }

    final rangeCount =
        (widget.chapters.length + mangaChapterRangeSize - 1) ~/
        mangaChapterRangeSize;
    final range = _rangeIndex != null && _rangeIndex! < rangeCount
        ? _rangeIndex
        : null;
    final narrowed = _chaptersForRangeAndQuery(range);
    // Reading and download eligibility can change in-place. Only the
    // chapter snapshot's range/query projection is safe to reuse.
    final chapters = switch (_filter) {
      MangaChapterFilter.all => narrowed,
      MangaChapterFilter.unread =>
        narrowed
            .where(
              (chapter) =>
                  repository.get(chapter.mangaId, chapter.id)?.isRead != true,
            )
            .toList(growable: false),
      MangaChapterFilter.downloaded =>
        narrowed
            .where((chapter) => _isDownloaded(chapter, progressById))
            .toList(growable: false),
    };
    // Slivers need random access to individual displayed rows, not a
    // second list holding all the same references just to reverse them.
    MangaChapter chapterAt(int index) =>
        chapters[ascending ? index : chapters.length - 1 - index];
    Widget emptyNote() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text(
          'لا توجد فصول هنا',
          key: const ValueKey<String>('manga-chapter-filter-empty'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );

    Widget row(MangaChapter chapter) {
      final publishedAt = chapter.publishedAt;
      final publishedLabel = publishedAt == null
          ? null
          : '${publishedAt.year.toString().padLeft(4, '0')}-'
                '${publishedAt.month.toString().padLeft(2, '0')}-'
                '${publishedAt.day.toString().padLeft(2, '0')}';
      return MangaChapterRow(
        key: ValueKey<String>('manga-chapter-row-${chapter.id}'),
        chapter: chapter,
        progress: repository.get(chapter.mangaId, chapter.id),
        publishedLabel: publishedLabel,
        selected: _selectedChapterIds.contains(chapter.id),
        selecting: _selecting,
        action: _downloadAction(context, chapter, progressById),
        onLongPress: () => _beginSelection(chapter),
        onTap: () {
          if (_selecting) {
            _toggleSelection(chapter);
          } else {
            widget.onOpen?.call(chapter);
          }
        },
      );
    }

    final toolbar = _toolbar(
      context,
      rangeCount: rangeCount,
      range: range,
      repository: repository,
    );

    if (widget.embedded) {
      // The page above already names this section, so the tools sit at its
      // head; the selection actions take their place while choosing. The
      // rows are built as they scroll into view: a long manga has well over
      // a thousand of them.
      return SliverMainAxisGroup(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: _withTransition(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[toolbar, const SizedBox(height: 8)],
              ),
              key: widget.revealKey,
            ),
          ),
          if (chapters.isEmpty) SliverToBoxAdapter(child: emptyNote()),
          SliverList.separated(
            itemCount: chapters.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) =>
                _withTransition(row(chapterAt(index))),
          ),
        ],
      );
    }

    return Stack(
      children: <Widget>[
        CustomScrollView(
          key: const PageStorageKey<String>('manga-chapter-list'),
          controller: _scrollController,
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              sliver: SliverToBoxAdapter(
                child: SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 12,
                    children: <Widget>[
                      Text(
                        l10n?.chapters ?? 'الفصول',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Put away while choosing chapters: the selection bar's own
            // read and unread actions take over.
            if (!_selecting)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                sliver: SliverToBoxAdapter(child: toolbar),
              ),
            if (chapters.isEmpty) SliverToBoxAdapter(child: emptyNote()),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverList.separated(
                itemCount: chapters.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) => row(chapterAt(index)),
              ),
            ),
            SliverToBoxAdapter(child: SizedBox(height: _selecting ? 148 : 96)),
          ],
        ),
        if (_selecting)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _selectionBar(context),
          ),
      ],
    );
  }
}
