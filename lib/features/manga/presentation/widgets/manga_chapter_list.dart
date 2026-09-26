import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/providers/episode_sort_provider.dart';
import '../../../../core/services/download_v2/download_v2_identity.dart';
import '../../../../core/storage/manga_reading_repository.dart';
import '../../../../core/utils/download_time_remaining.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/apple_liquid_glass.dart';
import '../../../details/presentation/widgets/details_hero_actions.dart';
import '../../../details/presentation/widgets/episode_action_chip.dart';
import '../../../library/presentation/download_progress_v2_provider.dart';
import '../../../library/presentation/downloads_provider.dart';
import '../manga_resume_chapter.dart';
import 'manga_chapter_browse.dart';
import 'manga_chapter_row.dart';

class MangaChapterList extends ConsumerStatefulWidget {
  const MangaChapterList({
    super.key,
    required this.chapters,
    this.onOpen,
    this.onDownload,
    this.downloads = const <DownloadItem>[],
    this.onDeleteDownload,
    this.embedded = false,
  });

  final List<MangaChapter> chapters;
  final ValueChanged<MangaChapter>? onOpen;
  final ValueChanged<MangaChapter>? onDownload;
  final List<DownloadItem> downloads;
  final ValueChanged<DownloadItem>? onDeleteDownload;

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

  /// The range menu's pick; null shows every chapter, which is the default.
  int? _rangeIndex;
  MangaChapterFilter _filter = MangaChapterFilter.all;

  /// The chapter "go to" or "current" last landed on, outlined in the list.
  String? _targetId;
  String _query = '';
  final TextEditingController _goToController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _targetKey = GlobalKey();

  /// The rows as last laid out, for scrolling to one not built yet.
  List<MangaChapter> _visible = const <MangaChapter>[];

  /// Roughly one row's height, to bring an unbuilt row near the screen
  /// before scrolling it exactly into place.
  static const double _approxRowExtent = 72;

  /// The toolbar above the rows, when embedded in a page's scroll.
  final GlobalKey _headKey = GlobalKey();

  bool get _selecting => _selectedChapterIds.isNotEmpty;

  bool get _isArabic =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  @override
  void dispose() {
    _goToController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Puts [chapter] on screen and outlines it. The range stays unless the
  /// chapter is outside it, and a filter that hides it is cleared.
  void _reveal(MangaChapter chapter) {
    final ranges = mangaChapterRanges(widget.chapters);
    final range = _rangeIndex;
    _goToController.clear();
    setState(() {
      _query = '';
      _filter = MangaChapterFilter.all;
      if (range != null &&
          (range >= ranges.length ||
              !ranges[range].any((c) => c.id == chapter.id))) {
        _rangeIndex = null;
      }
      _targetId = chapter.id;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToTarget());
  }

  void _scrollToTarget({int attempt = 0}) {
    if (!mounted) return;
    final target = _targetKey.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        alignment: 0.3,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    // A long list builds only the rows near the screen: work out from the
    // rows that are built where the target must be, jump there, and place
    // it exactly once it exists. A second pass corrects rows that are not
    // all the same height.
    if (attempt >= 3) return;
    final index = _visible.indexWhere((c) => c.id == _targetId);
    if (index < 0) return;
    final built = _builtRows();
    ScrollPosition? position;
    double? offset;
    if (built.isNotEmpty) {
      final first = built.first;
      final last = built.last;
      final extent = last.index > first.index
          ? (last.offset - first.offset) / (last.index - first.index)
          : _approxRowExtent;
      position = first.position;
      offset = first.offset + (index - first.index) * extent;
    } else if (widget.embedded) {
      // Inside the page's own scroll, with no row built yet: the rows
      // start below the toolbar, wherever the page has put it.
      final headContext = _headKey.currentContext;
      final head = headContext?.findRenderObject();
      if (head is! RenderBox || !head.attached) return;
      final viewport = RenderAbstractViewport.maybeOf(head);
      position = Scrollable.maybeOf(headContext!)?.position;
      if (viewport == null) return;
      offset =
          viewport.getOffsetToReveal(head, 0).offset +
          head.size.height +
          index * _approxRowExtent;
    } else if (_scrollController.hasClients) {
      position = _scrollController.position;
      offset = index * _approxRowExtent;
    }
    if (position == null || offset == null) return;
    position.jumpTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToTarget(attempt: attempt + 1),
    );
  }

  /// The rows built right now, in list order, each with where its scroll
  /// puts it at the top of the screen.
  List<({int index, double offset, ScrollPosition position})> _builtRows() {
    final indexOf = <String, int>{
      for (var i = 0; i < _visible.length; i++) _visible[i].id: i,
    };
    final rows = <({int index, double offset, ScrollPosition position})>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is MangaChapterRow) {
        final index = indexOf[widget.chapter.id];
        final box = element.renderObject;
        final position = Scrollable.maybeOf(element)?.position;
        if (index != null &&
            box is RenderBox &&
            box.attached &&
            position != null) {
          final viewport = RenderAbstractViewport.maybeOf(box);
          if (viewport != null) {
            rows.add((
              index: index,
              offset: viewport.getOffsetToReveal(box, 0).offset,
              position: position,
            ));
          }
        }
        return;
      }
      element.visitChildren(visit);
    }

    (context as Element).visitChildren(visit);
    rows.sort((a, b) => a.index.compareTo(b.index));
    return rows;
  }

  /// The search narrows the list as it is typed, as the anime episode
  /// search does, rather than jumping to one chapter.
  void _search(String raw) => setState(() {
    _query = raw;
    _targetId = null;
  });

  DownloadProgressData? _progressFor(
    MangaChapter chapter,
    Map<String, DownloadProgressData> progressById,
  ) {
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
      completedMangaChapterDownload(widget.downloads, chapter) != null ||
      _progressFor(chapter, progressById)?.status == TaskStatus.complete;

  /// The range menu: every chapter, or one run of fifty, each with how many
  /// of it are read.
  Widget _rangeMenu(
    BuildContext context,
    List<List<MangaChapter>> ranges,
    MangaReadingRepository repository,
  ) {
    final colors = Theme.of(context).colorScheme;
    final all = _isArabic ? 'كل الفصول' : 'All chapters';
    String rangeTitle(int i) =>
        '${_isArabic ? 'الفصول' : 'Chapters'} '
        '${mangaChapterRangeLabel(ranges[i], i)}';
    final range = _rangeIndex;
    return PopupMenuButton<int>(
      key: const ValueKey<String>('manga-chapter-range-menu'),
      tooltip: _isArabic ? 'نطاق الفصول' : 'Chapter range',
      initialValue: range ?? -1,
      onSelected: (value) => setState(() {
        _rangeIndex = value < 0 ? null : value;
        _targetId = null;
      }),
      itemBuilder: (_) => <PopupMenuEntry<int>>[
        PopupMenuItem<int>(value: -1, child: Text(all)),
        for (var i = 0; i < ranges.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: <Widget>[
                Expanded(child: Text(rangeTitle(i))),
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
                      return _isArabic ? 'مكتمل' : 'Done';
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
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: kDetailsHeroGlassFallback,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: colors.onSurfaceVariant.withValues(alpha: 0.16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              range == null ? all : rangeTitle(range),
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
          hintText: _isArabic ? 'ابحث عن فصل…' : 'Find a chapter…',
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
      MangaChapterFilter.all: _isArabic ? 'الكل' : 'All',
      MangaChapterFilter.unread: _isArabic ? 'غير المقروءة' : 'Unread',
      MangaChapterFilter.downloaded: _isArabic ? 'المنزّلة' : 'Downloaded',
    };
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final entry in labels.entries)
          ChoiceChip(
            key: ValueKey<String>('manga-chapter-filter-${entry.key.name}'),
            label: Text(entry.value),
            selected: _filter == entry.key,
            showCheckmark: false,
            onSelected: (_) => setState(() {
              _filter = entry.key;
              _targetId = null;
            }),
            labelStyle: TextStyle(
              fontSize: 13,
              color: _filter == entry.key ? colors.primary : colors.onSurface,
            ),
            selectedColor: colors.primary.withValues(alpha: 0.16),
            backgroundColor: kDetailsHeroGlassFallback,
            side: BorderSide(
              color: _filter == entry.key
                  ? colors.primary
                  : colors.onSurfaceVariant.withValues(alpha: 0.16),
            ),
            shape: const StadiumBorder(),
          ),
      ],
    );
  }

  /// Range, go-to, back to the current chapter, then the filters: every
  /// chapter is two steps away at most, however many there are.
  Widget _toolbar(
    BuildContext context, {
    required List<List<MangaChapter>> ranges,
    required MangaReadingRepository repository,
    required MangaChapter? current,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (ranges.length > 1) _rangeMenu(context, ranges, repository),
            _goToField(context),
            if (current != null)
              TextButton.icon(
                key: const ValueKey<String>('manga-chapter-to-current'),
                onPressed: () => _reveal(current),
                icon: const Icon(Icons.my_location_rounded, size: 18),
                label: Text(
                  _isArabic ? 'إلى الفصل الحالي' : 'To current chapter',
                ),
              ),
            if (trailing != null) trailing,
          ],
        ),
        const SizedBox(height: 10),
        _filterChips(context),
      ],
    );
  }

  Widget _sortButton(BuildContext context, bool ascending) {
    return SizedBox(
      height: 40,
      child: AppleLiquidGlassSurface(
        borderRadius: BorderRadius.circular(20),
        interactive: true,
        fallbackColor: kDetailsHeroGlassFallback,
        fallbackBorder: BorderSide(
          color: Theme.of(context).colorScheme.onSurfaceVariant
              .withValues(alpha: 0.12),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey<String>('manga-chapter-sort-toggle'),
            borderRadius: BorderRadius.circular(20),
            onTap: () => ref
                .read(episodeSortAscendingProvider.notifier)
                .setAscending(!ascending),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(
                ascending
                    ? Icons.arrow_downward_rounded
                    : Icons.arrow_upward_rounded,
                size: 22,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _toggleSelection(MangaChapter chapter) {
    setState(() {
      if (!_selectedChapterIds.add(chapter.id)) {
        _selectedChapterIds.remove(chapter.id);
      }
    });
  }

  void _beginSelection(MangaChapter chapter) {
    setState(() => _selectedChapterIds.add(chapter.id));
  }

  void _clearSelection() {
    if (!_selecting) return;
    setState(_selectedChapterIds.clear);
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

  Widget _selectionBar(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final count = _selectedChapterIds.length;
    final selectedLabel = isArabic ? 'تم تحديد $count' : '$count selected';

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
          child: SizedBox(
            height: 112,
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
                        tooltip: isArabic
                            ? 'إلغاء التحديد'
                            : 'Cancel selection',
                        visualDensity: VisualDensity.compact,
                        onPressed: _clearSelection,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: actionButton(
                          label: isArabic ? 'تمت قراءته' : 'Read',
                          icon: Icons.visibility_rounded,
                          outlined: false,
                          onPressed: () => _setSelectedRead(true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: actionButton(
                          label: isArabic ? 'غير مقروء' : 'Unread',
                          icon: Icons.visibility_off_rounded,
                          outlined: true,
                          onPressed: () => _setSelectedRead(false),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: isArabic
                            ? 'تحديد جميع الفصول'
                            : 'Select all chapters',
                        onPressed: () => setState(() {
                          _selectedChapterIds
                            ..clear()
                            ..addAll(
                              widget.chapters.map((chapter) => chapter.id),
                            );
                        }),
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
    final mangaId = chapter.mangaId.trim();
    if (mangaId.isNotEmpty && chapter.id.trim().isNotEmpty) {
      final logicalId = logicalDownloadIdForMangaChapter(
        mangaId: mangaId,
        chapterId: chapter.id,
      ).value;
      data = progressById[logicalId];
    }
    data ??= progressById[chapter.url];

    final completedDownload = completedMangaChapterDownload(
      widget.downloads,
      chapter,
    );
    final status = data?.status;
    final active =
        status == TaskStatus.running ||
        status == TaskStatus.enqueued ||
        status == TaskStatus.waitingToRetry ||
        status == TaskStatus.paused;
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

    if (completedDownload != null || status == TaskStatus.complete) {
      return EpisodeActionChip(
        tooltip:
            AppLocalizations.of(context)?.deleteDownload ??
            (isArabic ? 'حذف الفصل' : 'Delete chapter'),
        onPressed: completedDownload != null && widget.onDeleteDownload != null
            ? () => widget.onDeleteDownload!(completedDownload)
            : () {},
        icon: Icons.delete_outline_rounded,
        color: Theme.of(context).colorScheme.error,
      );
    }

    if (data != null && active) {
      if (status == TaskStatus.paused) {
        return EpisodeActionChip(
          tooltip: isArabic ? 'التنزيل متوقف مؤقتًا' : 'Download paused',
          onPressed: () {},
          child: Icon(
            Icons.pause_rounded,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
        );
      }
      final value = data.progress.clamp(0.0, 1.0);
      return EpisodeActionChip(
        tooltip: isArabic ? 'جارٍ تنزيل الفصل' : 'Downloading chapter',
        onPressed: () {},
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
          AppLocalizations.of(context)?.mangaDownloadChapter ??
          (isArabic ? 'تنزيل الفصل' : 'Download chapter'),
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
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final ascending = ref.watch(episodeSortAscendingProvider);

    if (widget.chapters.isEmpty) {
      final note = Center(
        child: Text(
          l10n?.mangaNoChapters ?? (isArabic ? 'لا توجد فصول' : 'No chapters'),
        ),
      );
      return widget.embedded ? SliverToBoxAdapter(child: note) : note;
    }

    final ordered = ascending
        ? widget.chapters
        : widget.chapters.reversed.toList(growable: false);
    final ranges = mangaChapterRanges(widget.chapters);
    final rangeIndex = _rangeIndex != null && _rangeIndex! < ranges.length
        ? _rangeIndex
        : null;
    final inRange = rangeIndex == null
        ? null
        : ranges[rangeIndex].map((c) => c.id).toSet();
    final chapters = ordered
        .where((chapter) {
          if (inRange != null && !inRange.contains(chapter.id)) return false;
          if (!mangaChapterMatchesQuery(chapter, _query)) return false;
          return switch (_filter) {
            MangaChapterFilter.all => true,
            MangaChapterFilter.unread =>
              repository.get(chapter.mangaId, chapter.id)?.isRead != true,
            MangaChapterFilter.downloaded => _isDownloaded(
              chapter,
              progressById,
            ),
          };
        })
        .toList(growable: false);
    _visible = chapters;

    // The chapter the reader is up to, marked in the list once they have
    // started; before that the button still leads to the first one.
    final resume = mangaResumeTarget(
      widget.chapters,
      (chapter) => repository.get(chapter.mangaId, chapter.id),
    );
    final currentId = resume == null || resume.kind == MangaResumeKind.start
        ? null
        : resume.chapter.id;

    Widget emptyNote() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text(
          isArabic ? 'لا توجد فصول هنا' : 'No chapters here',
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
      final isTarget = chapter.id == _targetId;
      final rowWidget = MangaChapterRow(
        key: ValueKey<String>('manga-chapter-row-${chapter.id}'),
        chapter: chapter,
        progress: repository.get(chapter.mangaId, chapter.id),
        publishedLabel: publishedLabel,
        current: chapter.id == currentId,
        highlighted: isTarget,
        selected: _selectedChapterIds.contains(chapter.id),
        action: _selecting
            ? null
            : _downloadAction(context, chapter, progressById),
        onLongPress: () => _beginSelection(chapter),
        onTap: () {
          if (_selecting) {
            _toggleSelection(chapter);
          } else {
            widget.onOpen?.call(chapter);
          }
        },
      );
      // Only the outlined row carries the key "go to" scrolls by.
      return isTarget
          ? KeyedSubtree(key: _targetKey, child: rowWidget)
          : rowWidget;
    }

    final toolbar = _toolbar(
      context,
      ranges: ranges,
      repository: repository,
      current: resume?.chapter,
      trailing: widget.embedded ? _sortButton(context, ascending) : null,
    );

    if (widget.embedded) {
      // The page above already names this section, so the tools sit at its
      // head; the selection actions take their place while choosing. The
      // rows are built as they scroll into view: a long manga has well over
      // a thousand of them.
      return SliverMainAxisGroup(
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Column(
              key: _headKey,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_selecting) _selectionBar(context) else toolbar,
                const SizedBox(height: 8),
              ],
            ),
          ),
          if (chapters.isEmpty) SliverToBoxAdapter(child: emptyNote()),
          SliverList.separated(
            itemCount: chapters.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) => row(chapters[index]),
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
                        l10n?.chapters ?? (isArabic ? 'الفصول' : 'Chapters'),
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      _sortButton(context, ascending),
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
                itemBuilder: (context, index) => row(chapters[index]),
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
