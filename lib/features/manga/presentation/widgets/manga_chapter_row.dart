import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/storage/manga_reading_repository.dart';
import '../../../../core/utils/manga_chapter_label.dart';

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
    this.current = false,
    this.highlighted = false,
  });

  final MangaChapter chapter;
  final MangaReadingProgress? progress;
  final String? publishedLabel;
  final Widget? action;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  /// The chapter the reader is up to: tinted, with how far into it they are.
  final bool current;

  /// The chapter "go to" just landed on, outlined so the eye finds it.
  final bool highlighted;

  String? get progressLabel {
    final state = progress;
    if (state == null || state.pageCount <= 0 || state.pagesRead <= 0) {
      return null;
    }
    return '${state.pagesRead}/${state.pageCount}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final isRead = progress?.isRead == true && !current;
    final accent = colors.primary;
    final foreground = current
        ? accent
        : colors.onSurface.withValues(alpha: isRead ? 0.52 : 1);
    final secondary = colors.onSurfaceVariant.withValues(
      alpha: isRead ? 0.45 : 0.72,
    );
    final state = progress;
    final partRead =
        current &&
        state != null &&
        !state.isRead &&
        state.pageCount > 0 &&
        state.pagesRead > 0;

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.15)
              : current
              ? accent.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: highlighted ? accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: <Widget>[
                // The name already carries the number, so the leading place
                // is the book: a second number beside it read as a repeat.
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.menu_book_rounded,
                  color: selected ? accent : foreground,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(
                              text: mangaChapterDisplayName(chapter),
                              style: TextStyle(color: foreground),
                            ),
                            if (progressLabel != null)
                              TextSpan(
                                text: ' • $progressLabel',
                                style: TextStyle(color: secondary),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
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
                      if (partRead) ...<Widget>[
                        const SizedBox(height: 6),
                        SizedBox(
                          width: 140,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              key: const ValueKey<String>(
                                'manga-chapter-current-progress',
                              ),
                              value: state.pagesRead / state.pageCount,
                              minHeight: 3,
                              color: accent,
                              backgroundColor: colors.onSurface.withValues(
                                alpha: 0.12,
                              ),
                            ),
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
