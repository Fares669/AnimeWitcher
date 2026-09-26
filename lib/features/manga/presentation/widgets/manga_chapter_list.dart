import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
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
import 'manga_chapter_browse.dart';
import 'manga_chapter_row.dart';

class MangaChapterSortButton extends ConsumerWidget {
  const MangaChapterSortButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ascending = ref.watch(episodeSortAscendingProvider);
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
}

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
  String _query = '';
  final TextEditingController _goToController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  OverlayEntry? _selectionOverlay;
  Animation<double>? _routeSecondaryAnimation;
  AnimationStatusListener? _routeStatusListener;

  bool get _selecting => _selectedChapterIds.isNotEmpty;

  bool get _isArabic =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

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
    _selectionOverlay?.remove();
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
      onSelected: (value) =>
          setState(() => _rangeIndex = value < 0 ? null : value),
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
            onSelected: (_) => setState(() => _filter = entry.key),
            labelStyle: TextStyle(
              fontSize: 13,
              color: _filter == entry.key ? colors.primary : colors.onSurface,
            ),
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

  /// Range and search tools, with reading-state filters below them.
  Widget _toolbar(
    BuildContext context, {
    required List<List<MangaChapter>> ranges,
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
            if (ranges.length > 1) _rangeMenu(context, ranges, repository),
            _goToField(context),
          ],
        ),
        const SizedBox(height: 10),
        _filterChips(context),
      ],
    );
  }

  void _syncSelectionOverlay() {
    if (!widget.embedded || !mounted) return;
    if (!_selecting) {
      _selectionOverlay?.remove();
      _selectionOverlay = null;
      return;
    }
    final existing = _selectionOverlay;
    if (existing != null) {
      existing.markNeedsBuild();
      return;
    }
    final entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: _selectionBar(overlayContext),
      ),
    );
    _selectionOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  void _toggleSelection(MangaChapter chapter) {
    setState(() {
      if (!_selectedChapterIds.add(chapter.id)) {
        _selectedChapterIds.remove(chapter.id);
      }
    });
    _syncSelectionOverlay();
  }

  void _beginSelection(MangaChapter chapter) {
    setState(() => _selectedChapterIds.add(chapter.id));
    _syncSelectionOverlay();
  }

  void _clearSelection() {
    if (!_selecting) return;
    setState(_selectedChapterIds.clear);
    _syncSelectionOverlay();
  }

  void _selectAll() {
    setState(() {
      _selectedChapterIds
        ..clear()
        ..addAll(widget.chapters.map((chapter) => chapter.id));
    });
    _syncSelectionOverlay();
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
      return MangaChapterRow(
        key: ValueKey<String>('manga-chapter-row-${chapter.id}'),
        chapter: chapter,
        progress: repository.get(chapter.mangaId, chapter.id),
        publishedLabel: publishedLabel,
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
    }

    final toolbar = _toolbar(
      context,
      ranges: ranges,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                toolbar,
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
          if (_selecting)
            const SliverToBoxAdapter(child: SizedBox(height: 132)),
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
                      const MangaChapterSortButton(),
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
