import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/manga_chapter_label.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../../../../shared/widgets/paged_rail.dart';
import 'home_section_header.dart';

/// "منذ 9 ساعة": how long ago a chapter came out.
String mangaChapterReleaseTime(DateTime? publishedAt) {
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

/// A new chapter's card: the manga's poster with the chapter on it and how
/// long ago it came out under the title. The rail and the full page share it.
class LatestMangaChapterCard extends StatelessWidget {
  const LatestMangaChapterCard({
    super.key,
    required this.entry,
    required this.heroTag,
    required this.onTap,
  });

  final MangaLatestChapter entry;
  final String heroTag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final manga = entry.manga;
    return MultimediaCard(
      imageUrl: AppImageFallbacks.poster(manga.posterUrl, label: manga.title),
      title: manga.title,
      episodeBadge: mangaChapterDisplayName(entry.chapter),
      subtitle: mangaChapterReleaseTime(entry.chapter.publishedAt),
      heroTag: heroTag,
      lookupTitle: manga.artworkLookupTitle,
      malId: manga.artworkLookupMalId,
      manga: true,
      onTap: onTap,
    );
  }
}

class LatestMangaChaptersSection extends StatefulWidget {
  const LatestMangaChaptersSection({
    super.key,
    required this.title,
    required this.items,
    required this.onTap,
    this.onViewAll,
  });

  final String title;
  final List<MangaLatestChapter> items;
  final ValueChanged<MangaLatestChapter> onTap;

  /// Opens every new chapter; the header shows "عرض الكل" when given.
  final VoidCallback? onViewAll;

  @override
  State<LatestMangaChaptersSection> createState() =>
      _LatestMangaChaptersSectionState();
}

class _LatestMangaChaptersSectionState
    extends State<LatestMangaChaptersSection> {
  final ScrollController _scrollController = ScrollController();

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
          HomeSectionHeader(
            title: widget.title,
            action: widget.onViewAll == null
                ? null
                : HomeViewAllButton(onTap: widget.onViewAll!),
          ),
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
                return Padding(
                  key: ValueKey('latest-manga-rail-$index'),
                  padding: EdgeInsetsDirectional.only(end: spacing),
                  child: LatestMangaChapterCard(
                    entry: entry,
                    heroTag:
                        'latest_manga_${entry.manga.url}_${entry.chapter.id}_$index',
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
