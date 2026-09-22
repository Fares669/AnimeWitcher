import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/storage/manga_reading_repository.dart';

class MangaChapterRow extends StatelessWidget {
  const MangaChapterRow({
    super.key,
    required this.chapter,
    this.progress,
    this.publishedLabel,
    this.action,
    this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  final MangaChapter chapter;
  final MangaReadingProgress? progress;
  final String? publishedLabel;
  final Widget? action;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  String get displayLabel {
    final state = progress;
    if (state == null || state.pageCount <= 0 || state.pagesRead <= 0) {
      return chapter.name;
    }
    return '${chapter.name} • ${state.pagesRead}/${state.pageCount}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final isRead = progress?.isRead == true;
    final foreground = theme.colorScheme.onSurface.withValues(
      alpha: isRead ? 0.52 : 1,
    );
    final secondary = theme.colorScheme.onSurfaceVariant.withValues(
      alpha: isRead ? 0.45 : 0.72,
    );

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.15)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Row(
              children: <Widget>[
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.menu_book_rounded,
                  color: selected ? theme.colorScheme.primary : foreground,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        displayLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: foreground,
                          fontWeight: isRead
                              ? FontWeight.w500
                              : FontWeight.w600,
                        ),
                      ),
                      if (publishedLabel != null) ...<Widget>[
                        const SizedBox(height: 3),
                        Text(
                          publishedLabel!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: secondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (action != null) ...<Widget>[
                  const SizedBox(width: 10),
                  action!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
