import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../l10n/generated/app_localizations.dart';

class MangaChapterList extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
        return ListTile(
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
                  tooltip: l10n?.mangaDownloadChapter ?? (isArabic ? 'تنزيل الفصل' : 'Download chapter'),
                  onPressed: () => onDownload!(chapter),
                  icon: const Icon(Icons.download_rounded),
                ),
        );
      },
    );
  }
}
