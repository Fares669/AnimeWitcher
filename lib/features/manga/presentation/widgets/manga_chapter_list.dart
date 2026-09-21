import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/storage/manga_reading_repository.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../reader/manga_reader_settings.dart';
import '../../reader/manga_reader_settings_provider.dart';

class MangaChapterList extends ConsumerWidget {
  const MangaChapterList({
    super.key,
    required this.chapters,
    this.onOpen,
    this.onDownload,
  });

  final List<MangaChapter> chapters;
  final ValueChanged<MangaChapter>? onOpen;
  final ValueChanged<MangaChapter>? onDownload;

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
        onDownload?.call(chapter);
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    if (chapters.isEmpty) {
      return Center(
        child: Text(
          l10n?.mangaNoChapters ?? (isArabic ? 'لا توجد فصول' : 'No chapters'),
        ),
      );
    }

    final readerSettings = ref.watch(mangaReaderSettingsProvider);
    final startAction = readerSettings.chapterSwipeStartAction;
    final endAction = readerSettings.chapterSwipeEndAction;

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
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
          onTap: onOpen == null ? null : () => onOpen!(chapter),
          trailing: onDownload == null
              ? null
              : IconButton(
                  tooltip:
                      l10n?.mangaDownloadChapter ??
                      (isArabic ? 'تنزيل الفصل' : 'Download chapter'),
                  onPressed: () => onDownload!(chapter),
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
    );
  }
}
