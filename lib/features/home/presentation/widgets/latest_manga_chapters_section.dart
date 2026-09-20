import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../../../../shared/widgets/paged_rail.dart';
import 'home_section_header.dart';

class LatestMangaChaptersSection extends StatefulWidget {
  const LatestMangaChaptersSection({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
  });

  final String title;
  final List<MangaLatestChapter> items;
  final ValueChanged<MangaLatestChapter> onTap;

  @override
  State<LatestMangaChaptersSection> createState() =>
      _LatestMangaChaptersSectionState();
}

class _LatestMangaChaptersSectionState
    extends State<LatestMangaChaptersSection> {
  final ScrollController _scrollController = ScrollController();

  String _chapterBadge(MangaChapter chapter) {
    final label = chapter.name.trim();
    if (label.contains('الفصل')) return label;
    final number = chapter.number;
    if (number != null) {
      final formatted = number == number.truncateToDouble()
          ? number.toInt().toString()
          : number.toString();
      return 'الفصل $formatted';
    }
    return label.isEmpty ? 'الفصل' : 'الفصل $label';
  }

  String _releaseTime(DateTime? publishedAt) {
    if (publishedAt == null) return '';
    var elapsed = DateTime.now().toUtc().difference(publishedAt.toUtc());
    if (elapsed.isNegative) elapsed = Duration.zero;

    if (elapsed.inMinutes < 1) return 'منذ لحظات';
    if (elapsed.inHours < 1) return 'منذ ${elapsed.inMinutes} دقيقة';
    if (elapsed.inDays < 1) return 'منذ ${elapsed.inHours} ساعة';
    if (elapsed.inDays < 30) return 'منذ ${elapsed.inDays} يوم';

    final months = (elapsed.inDays / 30).floor();
    if (months < 12) return 'منذ $months شهر';
    return 'منذ ${(months / 12).floor()} سنة';
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final isDesktop = context.isDesktop;
    final isHandsetLandscape = context.isHandsetLandscape;
    final spacing = isDesktop
        ? LayoutConstants.spacingLg
        : isHandsetLandscape
        ? ResponsiveBreakpoints.handsetLandscapeGridMaxSpacing
        : LayoutConstants.spacingSm;
    final horizontalPadding = isDesktop
        ? LayoutConstants.dashboardContentPadding
        : LayoutConstants.spacingMd;
    final cardWidth = MultimediaCardLayout.cardWidth(
      context,
      isPortrait: true,
      horizontalPadding: horizontalPadding,
      spacing: spacing,
    );
    final listHeight = MultimediaCardLayout.listHeight(
      cardWidth,
      isPortrait: true,
      isDesktop: isDesktop,
    );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeSectionHeader(title: widget.title),
          SizedBox(
            height: listHeight,
            child: PagedRail(
              controller: _scrollController,
              itemExtent: cardWidth + spacing,
              clipBehavior: Clip.none,
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              itemCount: widget.items.length,
              itemBuilder: (context, index) {
                final entry = widget.items[index];
                final manga = entry.manga;
                return Padding(
                  key: ValueKey('latest-manga-rail-$index'),
                  padding: EdgeInsetsDirectional.only(end: spacing),
                  child: MultimediaCard(
                    imageUrl: AppImageFallbacks.poster(
                      manga.posterUrl,
                      label: manga.title,
                    ),
                    title: manga.title,
                    episodeBadge: _chapterBadge(entry.chapter),
                    subtitle: _releaseTime(entry.chapter.publishedAt),
                    heroTag:
                        'latest_manga_${manga.url}_${entry.chapter.id}_$index',
                    lookupTitle: manga.artworkLookupTitle,
                    malId: manga.artworkLookupMalId,
                    onTap: () => widget.onTap(entry),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
