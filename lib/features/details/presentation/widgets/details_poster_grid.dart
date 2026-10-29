import 'package:flutter/material.dart';

import '../../../../core/account/animewitcher_character_models.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/cards_wrapper.dart';
import '../../../../shared/widgets/multimedia_card.dart';

const int detailsExtraTabGridColumns = 3;
const double detailsExtraTabCrossAxisSpacing = 12;
const double detailsExtraTabMainAxisSpacing = 14;

int detailsExtraTabCrossAxisCount(BuildContext context) {
  return context.isHandsetLandscape
      ? ResponsiveBreakpoints.handsetLandscapeAnimeColumns
      : detailsExtraTabGridColumns;
}

/// How many cards the grid below actually lays across [width].
///
/// [detailsExtraTabCrossAxisCount] is three, which is not what these grids
/// do: they hand [ResponsiveBreakpoints.animeGridDelegate] a maximum card
/// width and let it decide. Measuring the body with three reserved two rows
/// of wide, tall cards for what a desktop window renders as one row of narrow
/// ones — a poster's height of black under every one of these sections.
///
/// The delegate answers in four ways, and so does this. The last of them
/// divides the width the grid is actually given, not the window's: they are
/// not the same number, and using the window here counted columns the grid
/// had no room for.
int detailsExtraTabRenderedColumns(BuildContext context, double width) {
  if (ResponsiveBreakpoints.isDesktopLandscape(context)) {
    return ResponsiveBreakpoints.desktopLandscapeColumnsForViewport(context);
  }
  if (ResponsiveBreakpoints.isHandsetLandscape(context)) {
    return ResponsiveBreakpoints.handsetLandscapeAnimeColumns;
  }
  if (ResponsiveBreakpoints.isHandset(context)) {
    return MultimediaCardLayout.handsetPortraitGridColumns;
  }

  // SliverGridDelegateWithMaxCrossAxisExtent's own arithmetic.
  final spacing = MultimediaCardLayout.catalogGridCrossAxisSpacing(
    context,
    fallback: detailsExtraTabCrossAxisSpacing,
  );
  final maxExtent = context.isDesktop ? 240.0 : 150.0;
  if (width <= 0) return 1;
  return (width / (maxExtent + spacing)).ceil().clamp(1, 40);
}

/// Height of two poster-card rows in the extra-tabs body.
double detailsExtraTabBodyHeight(
  BuildContext context,
  double width, {

  /// How many rows of cards to leave room for.
  ///
  /// Two is the most any of these tabs shows, but a title with five similar
  /// anime fills one — and reserving the second regardless left half a
  /// screen of nothing under it, with everything below pushed off the page.
  int rows = 2,
}) {
  final isDesktop = context.isDesktop;
  final columns = detailsExtraTabRenderedColumns(context, width);
  final crossSpacing = MultimediaCardLayout.catalogGridCrossAxisSpacing(
    context,
    fallback: detailsExtraTabCrossAxisSpacing,
  );
  final mainSpacing = MultimediaCardLayout.catalogGridMainAxisSpacing(
    context,
    fallback: detailsExtraTabMainAxisSpacing,
  );
  final childWidth = (width - crossSpacing * (columns - 1)) / columns;
  final childHeight =
      childWidth /
      MultimediaCardLayout.gridAspectRatio(
        isPortrait: true,
        isDesktop: isDesktop,
      );
  final rowCount = rows.clamp(1, 2);
  return childHeight * rowCount + (rowCount > 1 ? mainSpacing : 0);
}

class ExtraTabGridPreview {
  const ExtraTabGridPreview({required this.items, required this.showMore});

  final List<MultimediaItem> items;
  final bool showMore;
}

/// Caps similar/related extra-tab grids at 6 slots: 5 posters + المزيد
/// when there are more than 6 works.
ExtraTabGridPreview extraTabGridPreview(
  List<MultimediaItem> items, {
  required bool hasMore,
}) {
  final showMore = hasMore || items.length > animeWitcherExtraTabPreviewSlots;
  if (!showMore) {
    return ExtraTabGridPreview(items: items, showMore: false);
  }
  return ExtraTabGridPreview(
    items: items
        .take(animeWitcherExtraTabPreviewItemsWhenMore)
        .toList(growable: false),
    showMore: true,
  );
}

class DetailsPosterGrid extends StatelessWidget {
  const DetailsPosterGrid({
    super.key,
    required this.items,
    required this.onItemTap,
    this.showRelationBadge = false,
    this.hasMore = false,
    this.onShowMore,
    this.keyPrefix = 'details-poster-grid',
  });

  final List<MultimediaItem> items;
  final void Function(MultimediaItem) onItemTap;
  final bool showRelationBadge;
  final bool hasMore;
  final VoidCallback? onShowMore;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final extra = hasMore && onShowMore != null ? 1 : 0;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: GridView.builder(
        key: ValueKey('$keyPrefix-grid'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
          context,
          maxCrossAxisExtent: isDesktop ? 240 : 150,
          childAspectRatio: MultimediaCardLayout.gridAspectRatio(
            isPortrait: true,
            isDesktop: isDesktop,
          ),
          crossAxisSpacing: MultimediaCardLayout.catalogGridCrossAxisSpacing(
            context,
            fallback: detailsExtraTabCrossAxisSpacing,
          ),
          mainAxisSpacing: MultimediaCardLayout.catalogGridMainAxisSpacing(
            context,
            fallback: detailsExtraTabMainAxisSpacing,
          ),
          handsetPortraitCrossAxisCount:
              MultimediaCardLayout.handsetPortraitGridColumns,
        ),
        itemCount: items.length + extra,
        itemBuilder: (context, index) {
          if (index >= items.length) {
            return DetailsShowMoreTile(
              key: ValueKey('$keyPrefix-more'),
              onTap: onShowMore!,
            );
          }
          final item = items[index];
          return MultimediaCard.fromItem(
            key: ValueKey('$keyPrefix-$index'),
            item: item,
            heroTag: heroTagWithUrl(keyPrefix, item, index),
            showRelationBadge: showRelationBadge,
            onTap: () => onItemTap(item),
          );
        },
      ),
    );
  }
}

class DetailsShowMoreTile extends StatelessWidget {
  const DetailsShowMoreTile({
    super.key,
    required this.onTap,
    this.compact = false,
  });

  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return CardsWrapper(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MultimediaCardLayout.posterRadius),
      child: SizedBox.expand(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(
              MultimediaCardLayout.posterRadius,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.more_horiz_rounded,
                size: compact ? 28 : 36,
                color: colors.primary,
              ),
              const SizedBox(height: 8),
              Text(
                animeWitcherShowMoreLabel,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
