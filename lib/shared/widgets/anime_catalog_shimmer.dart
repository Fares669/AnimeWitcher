import 'package:flutter/material.dart';

import '../../core/utils/responsive_breakpoints.dart';
import 'catalog_direction.dart';
import 'multimedia_card.dart';
import 'shimmer_placeholder.dart';

/// Skeleton card matching the real poster + caption layout.
class AnimePosterShimmer extends StatelessWidget {
  const AnimePosterShimmer({
    super.key,
    this.isPortrait = true,
    this.characterCaptionSpace = false,
  });

  final bool isPortrait;
  final bool characterCaptionSpace;

  Widget _line({
    required double widthFactor,
    required double height,
    double borderRadius = 4,
  }) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: FractionallySizedBox(
        widthFactor: widthFactor,
        child: ShimmerPlaceholder.rectangular(
          height: height,
          borderRadius: borderRadius,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDesktopLandscape = context.isDesktopLandscape;
    final isDesktop = context.isDesktop;
    final effectiveCompact = isDesktopLandscape;
    final titleHeight =
        (effectiveCompact ? 12.0 : (isDesktop ? 15.0 : 13.0)) * 1.2;
    final subtitleHeight =
        (effectiveCompact ? 10.0 : (isDesktop ? 12.0 : 11.0)) * 1.2;
    final characterTitleHeight =
        MultimediaCardLayout.characterCaptionExtent(context) - 6;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ShimmerPlaceholder.rectangular(
            borderRadius: MultimediaCardLayout.posterRadius,
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(top: 6, start: 2, end: 2),
          child: Directionality(
            // Real catalog card captions stay physically left-aligned even
            // when their surrounding rail follows Arabic RTL ordering.
            textDirection: TextDirection.ltr,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _line(
                  widthFactor: 0.82,
                  height: characterCaptionSpace
                      ? characterTitleHeight
                      : titleHeight,
                ),
                if (!characterCaptionSpace) ...[
                  const SizedBox(height: 2),
                  _line(widthFactor: 0.52, height: subtitleHeight),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-page anime grid skeleton — same style as the home catalog shimmer.
class AnimeCatalogShimmer extends StatelessWidget {
  const AnimeCatalogShimmer({
    super.key,
    this.itemCount,
    this.padding,
    this.physics = const AlwaysScrollableScrollPhysics(),
    this.characterCaptionSpace = false,
  });

  final int? itemCount;
  final EdgeInsetsGeometry? padding;
  final ScrollPhysics? physics;

  /// Character tiles render the poster + one name skeleton only.
  final bool characterCaptionSpace;

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final count = itemCount ?? (isDesktop ? 18 : 12);
    final horizontalPadding = MultimediaCardLayout.catalogGridHorizontalPadding(
      context,
    );
    final crossAxisSpacing = MultimediaCardLayout.catalogGridCrossAxisSpacing(
      context,
    );
    final mainAxisSpacing = MultimediaCardLayout.catalogGridMainAxisSpacing(
      context,
    );
    final childAspectRatio = characterCaptionSpace
        ? MultimediaCardLayout.characterGridAspectRatio
        : MultimediaCardLayout.gridAspectRatio(
            isPortrait: true,
            isDesktop: isDesktop,
          );
    return CatalogDirection(
      child: GridView.builder(
        physics: physics,
        padding:
            padding ??
            EdgeInsets.fromLTRB(
              horizontalPadding,
              16,
              horizontalPadding,
              110,
            ),
        gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
          context,
          maxCrossAxisExtent: isDesktop ? 240 : 150,
          childAspectRatio: childAspectRatio,
          crossAxisSpacing: crossAxisSpacing,
          mainAxisSpacing: mainAxisSpacing,
          handsetPortraitCrossAxisCount:
              MultimediaCardLayout.handsetPortraitGridColumns,
          horizontalPadding: horizontalPadding,
        ),
        itemCount: count,
        itemBuilder: (context, index) => AnimePosterShimmer(
          key: ValueKey('anime-catalog-shimmer-$index'),
          characterCaptionSpace: characterCaptionSpace,
        ),
      ),
    );
  }
}
