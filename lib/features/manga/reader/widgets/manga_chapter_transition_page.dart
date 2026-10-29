// Adapted from Mangayomi's ChapterTransitionPage (Apache-2.0).
// See docs/third_party/MANGAYOMI_READER_NOTICE.md.
import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';

bool mangaReaderShouldAdvancePastTransition({
  required double extentAfter,
  required double overscroll,
}) => extentAfter <= 0.5 && overscroll > 0;

/// How much of the trailing divider must be on screen before the scrolling
/// readers move on by themselves: enough that reaching it means the chapter
/// is finished, not merely that its edge peeked into the viewport.
const double mangaReaderTrailingAdvanceVisibility = 0.6;

/// The slim divider the scrolling readers leave between chapters instead of
/// the full transition page: the finished chapter above, the next chapter
/// below, and nothing to stop and tap — the readers advance on their own
/// when this scrolls into view. Tapping the next chapter still works.
class MangaReaderChapterDivider extends StatelessWidget {
  const MangaReaderChapterDivider({
    super.key,
    required this.currentChapter,
    required this.nextChapter,
    required this.mangaName,
    this.onContinue,
  });

  final MangaChapter currentChapter;
  final MangaChapter? nextChapter;
  final String mangaName;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'تم إكمال الفصل',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  currentChapter.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Icon(
                  nextChapter == null
                      ? Icons.check_circle_outline
                      : Icons.keyboard_arrow_down,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 6),
                if (nextChapter != null)
                  _nextCard(context)
                else
                  Text(
                    'لا يوجد فصل تالٍ — أنهيت قراءة $mangaName',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _nextCard(BuildContext context) {
    final theme = Theme.of(context);
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'الفصل التالي',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer.withValues(
                alpha: 0.7,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            nextChapter!.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    if (onContinue == null) return card;
    return Semantics(
      button: true,
      label: 'متابعة إلى الفصل التالي',
      child: GestureDetector(
        key: const ValueKey<String>('manga-reader-next-chapter-transition'),
        behavior: HitTestBehavior.opaque,
        onTap: onContinue,
        child: card,
      ),
    );
  }
}

class MangaReaderChapterTransitionPage extends StatelessWidget {
  const MangaReaderChapterTransitionPage({
    super.key,
    required this.currentChapter,
    required this.nextChapter,
    required this.mangaName,
    required this.readerMode,
    this.onContinue,
  });

  final MangaChapter currentChapter;
  final MangaChapter? nextChapter;
  final String mangaName;
  final MangaReaderMode readerMode;
  final VoidCallback? onContinue;

  String _t(BuildContext context, String en, String ar) => ar;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: readerMode.isVertical ? _vertical(context) : _horizontal(context),
  );

  Widget _vertical(BuildContext context) => Center(
    child: LayoutBuilder(
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.scaleDown,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: constraints.maxWidth.clamp(100.0, 480.0),
            maxHeight: double.infinity,
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.auto_stories_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 20),
                Text(
                  _t(context, 'End of chapter', 'نهاية الفصل'),
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                _chapterCard(
                  context,
                  label: _t(context, 'Chapter completed', 'تم إكمال الفصل'),
                  name: currentChapter.name,
                  primary: false,
                ),
                const SizedBox(height: 16),
                Icon(
                  nextChapter == null
                      ? Icons.check_circle_outline
                      : Icons.keyboard_arrow_down,
                  size: 32,
                ),
                const SizedBox(height: 16),
                if (nextChapter != null) ...<Widget>[
                  _chapterCard(
                    context,
                    label: _t(context, 'Next chapter', 'الفصل التالي'),
                    name: nextChapter!.name,
                    primary: true,
                    onTap: onContinue,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _t(
                      context,
                      'Continue to next chapter',
                      'متابعة إلى الفصل التالي',
                    ),
                  ),
                ] else
                  _endCard(context),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _horizontal(BuildContext context) {
    final current = _chapterCard(
      context,
      label: _t(context, 'Chapter completed', 'تم إكمال الفصل'),
      name: currentChapter.name,
      primary: false,
    );
    final next = nextChapter == null
        ? _endCard(context)
        : _chapterCard(
            context,
            label: _t(context, 'Next chapter', 'الفصل التالي'),
            name: nextChapter!.name,
            primary: true,
            onTap: onContinue,
          );
    final arrow = Icon(
      nextChapter == null
          ? Icons.check_circle_outline
          : readerMode.isRtl
          ? Icons.keyboard_arrow_left
          : Icons.keyboard_arrow_right,
      size: 36,
    );

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.auto_stories_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              _t(context, 'End of chapter', 'نهاية الفصل'),
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: IntrinsicHeight(
                child: Row(
                  children: readerMode.isRtl
                      ? <Widget>[
                          Expanded(child: next),
                          const SizedBox(width: 12),
                          Center(child: arrow),
                          const SizedBox(width: 12),
                          Expanded(child: current),
                        ]
                      : <Widget>[
                          Expanded(child: current),
                          const SizedBox(width: 12),
                          Center(child: arrow),
                          const SizedBox(width: 12),
                          Expanded(child: next),
                        ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chapterCard(
    BuildContext context, {
    required String label,
    required String name,
    required bool primary,
    VoidCallback? onTap,
  }) {
    final theme = Theme.of(context);
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: primary
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: primary
              ? theme.colorScheme.primary.withValues(alpha: 0.3)
              : theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return card;
    return Semantics(
      button: true,
      label: _t(context, 'Continue to next chapter', 'متابعة إلى الفصل التالي'),
      child: GestureDetector(
        key: const ValueKey<String>('manga-reader-next-chapter-transition'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: card,
      ),
    );
  }

  Widget _endCard(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(Icons.last_page, size: 24),
        const SizedBox(height: 6),
        Text(
          _t(context, 'No next chapter', 'لا يوجد فصل تالٍ'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          _t(
            context,
            'You have finished reading $mangaName',
            'أنهيت قراءة $mangaName',
          ),
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}
