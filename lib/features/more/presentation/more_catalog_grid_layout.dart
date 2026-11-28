import 'package:flutter/widgets.dart';

import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/multimedia_card.dart';

/// Matches portrait cover geometry across the ranking and broadcast tabs.
({EdgeInsets padding, SliverGridDelegate delegate}) moreCatalogGridLayout(
  BuildContext context,
) {
  final isDesktop = context.isDesktop;
  final side = MultimediaCardLayout.catalogGridHorizontalPadding(context);
  return (
    padding: EdgeInsets.fromLTRB(side, 16, side, 110),
    delegate: ResponsiveBreakpoints.animeGridDelegate(
      context,
      maxCrossAxisExtent: isDesktop ? 240 : 150,
      childAspectRatio: MultimediaCardLayout.gridAspectRatio(
        isPortrait: true,
        isDesktop: isDesktop,
      ),
      crossAxisSpacing: MultimediaCardLayout.catalogGridCrossAxisSpacing(
        context,
      ),
      mainAxisSpacing: MultimediaCardLayout.catalogGridMainAxisSpacing(context),
      handsetPortraitCrossAxisCount:
          MultimediaCardLayout.handsetPortraitGridColumns,
      horizontalPadding: side,
    ),
  );
}
