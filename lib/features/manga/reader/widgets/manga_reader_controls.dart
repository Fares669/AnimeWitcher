import 'package:flutter/material.dart';

import '../../../../shared/widgets/apple_liquid_glass.dart';
import '../manga_reader_controller.dart';

class MangaReaderControls extends StatelessWidget
    implements PreferredSizeWidget {
  const MangaReaderControls({
    super.key,
    required this.chapterLabel,
    required this.pageIndex,
    required this.pageCount,
    required this.mode,
    required this.onModeChanged,
    this.onPreviousChapter,
    this.onNextChapter,
  });

  final String chapterLabel;
  final int pageIndex;
  final int pageCount;
  final MangaReaderMode mode;
  final ValueChanged<MangaReaderMode> onModeChanged;
  final VoidCallback? onPreviousChapter;
  final VoidCallback? onNextChapter;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final pageLabel = pageCount <= 0
        ? ''
        : '${pageIndex + 1} / $pageCount';

    return AppBar(
      automaticallyImplyLeading: !appleUsesPersistentLiquidGlassHeader,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            chapterLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (pageLabel.isNotEmpty)
            Text(
              pageLabel,
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: isArabic ? 'الفصل السابق' : 'Previous chapter',
          onPressed: onPreviousChapter,
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        IconButton(
          tooltip: isArabic ? 'الفصل التالي' : 'Next chapter',
          onPressed: onNextChapter,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
        PopupMenuButton<MangaReaderMode>(
          tooltip: isArabic ? 'طريقة القراءة' : 'Reading mode',
          initialValue: mode,
          onSelected: onModeChanged,
          itemBuilder: (context) => [
            PopupMenuItem(
              value: MangaReaderMode.webtoon,
              child: Text(isArabic ? 'تمرير عمودي' : 'Webtoon'),
            ),
            PopupMenuItem(
              value: MangaReaderMode.pagedRtl,
              child: Text(isArabic ? 'صفحات من اليمين' : 'Paged RTL'),
            ),
            PopupMenuItem(
              value: MangaReaderMode.pagedLtr,
              child: Text(isArabic ? 'صفحات من اليسار' : 'Paged LTR'),
            ),
          ],
          icon: const Icon(Icons.chrome_reader_mode_rounded),
        ),
      ],
    );
  }
}
