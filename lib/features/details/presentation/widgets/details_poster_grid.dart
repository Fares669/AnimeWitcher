import 'package:flutter/material.dart';

import '../../../../core/account/animewitcher_character_models.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/cards_wrapper.dart';
import '../../../../shared/widgets/multimedia_card.dart';

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
          crossAxisSpacing: 12,
          mainAxisSpacing: 14,
          handsetPortraitCrossAxisCount: 3,
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
            heroTag: '${keyPrefix}_${item.url}_$index',
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
