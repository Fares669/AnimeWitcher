import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/utils/image_fallbacks.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../downloads_provider.dart';

class CompletedDownloadChapterCard extends StatelessWidget {
  const CompletedDownloadChapterCard({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onDelete,
  });

  final DownloadItem item;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chapter = item.chapter;
    final l10n = AppLocalizations.of(context)!;
    final title = chapter?.name.trim().isNotEmpty == true
        ? chapter!.name.trim()
        : l10n.mangaChapterCount(1);

    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(LayoutConstants.radiusLg),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(LayoutConstants.radiusLg),
          border: Border.all(
            color: theme.dividerColor.withValues(alpha: 0.35),
          ),
        ),
        padding: const EdgeInsets.all(LayoutConstants.spacingSm),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(LayoutConstants.radiusMd),
              child: SizedBox(
                width: 72,
                height: 104,
                child: CachedNetworkImage(
                  imageUrl:
                      AppImageFallbacks.poster(
                        item.item.posterUrl,
                        label: item.item.title,
                      ) ??
                      '',
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.menu_book_rounded),
                  ),
                ),
              ),
            ),
            const SizedBox(width: LayoutConstants.spacingMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.check_circle_rounded,
                        size: 15,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        l10n.mangaCompleted,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: l10n.mangaDeleteChapter,
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded),
              color: theme.colorScheme.error,
            ),
          ],
        ),
      ),
    );
  }
}
