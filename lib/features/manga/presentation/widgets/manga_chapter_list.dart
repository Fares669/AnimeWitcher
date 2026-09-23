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
import 'manga_chapter_row.dart';

class MangaChapterList extends ConsumerStatefulWidget {
  const MangaChapterList({
    super.key,
    required this.chapters,
    this.onOpen,
    this.onDownload,
    this.downloads = const <DownloadItem>[],
    this.onDeleteDownload,
  });

  final List<MangaChapter> chapters;
  final ValueChanged<MangaChapter>? onOpen;
  final ValueChanged<MangaChapter>? onDownload;
  final List<DownloadItem> downloads;
  final ValueChanged<DownloadItem>? onDeleteDownload;

  @override
  ConsumerState<MangaChapterList> createState() => _MangaChapterListState();
}

class _MangaChapterListState extends ConsumerState<MangaChapterList> {
  final Set<String> _selectedChapterIds = <String>{};

  bool get _selecting => _selectedChapterIds.isNotEmpty;

  Widget _sortButton(BuildContext context, bool ascending) {
    return SizedBox(
      height: 40,
      child: AppleLiquidGlassSurface(
        borderRadius: BorderRadius.circular(20),
        interactive: true,
        fallbackColor: kDetailsHeroGlassFallback,
        fallbackBorder: BorderSide(
          color: Theme.of(
            context,
          ).colorScheme.onSurfaceVariant.withValues(alpha: 0.12),
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
      await repository.setReadStates(
        entry.key,
        entry.value,
        read: read,
      );
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
                            ..addAll(widget.chapters.map((chapter) => chapter.id));
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
      return Center(
        child: Text(
          l10n?.mangaNoChapters ?? (isArabic ? 'لا توجد فصول' : 'No chapters'),
        ),
      );
    }

    final chapters = ascending
        ? widget.chapters
        : widget.chapters.reversed.toList(growable: false);

    return Stack(
      children: <Widget>[
        CustomScrollView(
          key: const PageStorageKey<String>('manga-chapter-list'),
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
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      _sortButton(context, ascending),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverList.separated(
                itemCount: chapters.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final chapter = chapters[index];
                  final publishedAt = chapter.publishedAt;
                  final publishedLabel = publishedAt == null
                      ? null
                      : '${publishedAt.year.toString().padLeft(4, '0')}-'
                            '${publishedAt.month.toString().padLeft(2, '0')}-'
                            '${publishedAt.day.toString().padLeft(2, '0')}';
                  final progress = repository.get(
                    chapter.mangaId,
                    chapter.id,
                  );
                  final selected = _selectedChapterIds.contains(chapter.id);

                  return MangaChapterRow(
                    key: ValueKey<String>('manga-chapter-row-${chapter.id}'),
                    chapter: chapter,
                    progress: progress,
                    publishedLabel: publishedLabel,
                    selected: selected,
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
                },
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(height: _selecting ? 148 : 96),
            ),
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
