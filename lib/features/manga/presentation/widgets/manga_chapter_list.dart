import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/storage/manga_reading_repository.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/apple_liquid_glass.dart';
import '../../../details/presentation/widgets/details_hero_actions.dart';
import '../../reader/manga_reader_settings.dart';
import '../../reader/manga_reader_settings_provider.dart';

class MangaChapterList extends ConsumerStatefulWidget {
  const MangaChapterList({
    super.key,
    required this.chapters,
    this.onOpen,
    this.onDownload,
  });

  final List<MangaChapter> chapters;
  final ValueChanged<MangaChapter>? onOpen;
  final ValueChanged<MangaChapter>? onDownload;

  @override
  ConsumerState<MangaChapterList> createState() => _MangaChapterListState();
}

class _MangaChapterListState extends ConsumerState<MangaChapterList> {
  bool _ascending = false;

  Future<void> _performSwipeAction(
    WidgetRef ref,
    MangaChapter chapter,
    MangaReaderChapterSwipeAction action,
  ) async {
    switch (action) {
      case MangaReaderChapterSwipeAction.toggleBookmark:
        await ref
            .read(mangaReadingRepositoryProvider)
            .toggleBookmark(chapter.mangaId, chapter.id);
      case MangaReaderChapterSwipeAction.toggleRead:
        await ref
            .read(mangaReadingRepositoryProvider)
            .toggleRead(chapter.mangaId, chapter.id);
      case MangaReaderChapterSwipeAction.download:
        widget.onDownload?.call(chapter);
      case MangaReaderChapterSwipeAction.disabled:
        break;
    }
  }

  DismissDirection _dismissDirection(
    MangaReaderChapterSwipeAction start,
    MangaReaderChapterSwipeAction end,
  ) {
    final startEnabled = start != MangaReaderChapterSwipeAction.disabled;
    final endEnabled = end != MangaReaderChapterSwipeAction.disabled;
    if (startEnabled && endEnabled) return DismissDirection.horizontal;
    if (startEnabled) return DismissDirection.startToEnd;
    if (endEnabled) return DismissDirection.endToStart;
    return DismissDirection.none;
  }

  Widget _swipeBackground(
    BuildContext context,
    MangaReaderChapterSwipeAction action, {
    required AlignmentGeometry alignment,
  }) {
    final icon = switch (action) {
      MangaReaderChapterSwipeAction.toggleBookmark => Icons.bookmark_rounded,
      MangaReaderChapterSwipeAction.toggleRead => Icons.done_all_rounded,
      MangaReaderChapterSwipeAction.download => Icons.download_rounded,
      MangaReaderChapterSwipeAction.disabled => Icons.block_rounded,
    };
    return Container(
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Icon(icon, color: Theme.of(context).colorScheme.onPrimaryContainer),
    );
  }

  Widget _sortButton(BuildContext context) {
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
            onTap: () => setState(() => _ascending = !_ascending),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Icon(
                _ascending
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    if (widget.chapters.isEmpty) {
      return Center(
        child: Text(
          l10n?.mangaNoChapters ?? (isArabic ? 'لا توجد فصول' : 'No chapters'),
        ),
      );
    }

    final chapters = _ascending
        ? widget.chapters.reversed.toList(growable: false)
        : widget.chapters;
    final readerSettings = ref.watch(mangaReaderSettingsProvider);
    final startAction = readerSettings.chapterSwipeStartAction;
    final endAction = readerSettings.chapterSwipeEndAction;

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
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
                _sortButton(context),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
            itemCount: chapters.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final chapter = chapters[index];
              final publishedAt = chapter.publishedAt;
              final publishedLabel = publishedAt == null
                  ? null
                  : publishedAt.year.toString().padLeft(4, '0') +
                        '-' +
                        publishedAt.month.toString().padLeft(2, '0') +
                        '-' +
                        publishedAt.day.toString().padLeft(2, '0');

              final tile = ListTile(
                leading: const Icon(Icons.menu_book_rounded),
                title: Text(
                  chapter.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: publishedLabel == null ? null : Text(publishedLabel),
                onTap: widget.onOpen == null
                    ? null
                    : () => widget.onOpen!(chapter),
                trailing: widget.onDownload == null
                    ? null
                    : IconButton(
                        tooltip:
                            l10n?.mangaDownloadChapter ??
                            (isArabic ? 'تنزيل الفصل' : 'Download chapter'),
                        onPressed: () => widget.onDownload!(chapter),
                        icon: const Icon(Icons.download_rounded),
                      ),
              );

              return Dismissible(
                key: ValueKey<String>('manga-chapter-swipe-${chapter.id}'),
                direction: _dismissDirection(startAction, endAction),
                background: _swipeBackground(
                  context,
                  startAction,
                  alignment: AlignmentDirectional.centerStart,
                ),
                secondaryBackground: _swipeBackground(
                  context,
                  endAction,
                  alignment: AlignmentDirectional.centerEnd,
                ),
                confirmDismiss: (direction) async {
                  final action = direction == DismissDirection.startToEnd
                      ? startAction
                      : endAction;
                  await _performSwipeAction(ref, chapter, action);
                  return false;
                },
                child: tile,
              );
            },
          ),
        ),
      ],
    );
  }
}
