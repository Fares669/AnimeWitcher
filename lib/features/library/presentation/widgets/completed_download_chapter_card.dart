import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/manga_reading_repository.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../details/presentation/widgets/episode_action_chip.dart';
import '../../../manga/presentation/widgets/manga_chapter_row.dart';
import '../downloads_provider.dart';

class CompletedDownloadChapterCard extends ConsumerWidget {
  const CompletedDownloadChapterCard({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onDelete,
    this.selecting = false,
    this.selected = false,
  });

  final DownloadItem item;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(mangaReadingRevisionProvider);
    final chapter = item.chapter;
    if (chapter == null) return const SizedBox.shrink();

    final repository = ref.watch(mangaReadingRepositoryProvider);
    final progress = repository.get(chapter.mangaId, chapter.id);

    final l10n = AppLocalizations.of(context);

    return MangaChapterRow(
      chapter: chapter,
      progress: progress,
      onTap: onOpen,
      selected: selected,
      selecting: selecting,
      action: selecting
          ? const SizedBox.square(dimension: EpisodeActionChip.defaultSize)
          : EpisodeActionChip(
              tooltip: l10n?.mangaDeleteChapter ?? 'حذف الفصل',
              onPressed: onDelete,
              icon: Icons.delete_outline_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
    );
  }
}
