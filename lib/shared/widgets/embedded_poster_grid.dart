import 'package:flutter/widgets.dart';

import '../../core/utils/responsive_breakpoints.dart';
import 'multimedia_card.dart';

const double embeddedPosterGridCrossAxisSpacing = 12;
const double embeddedPosterGridMainAxisSpacing = 14;

/// Poster grid embedded in the surrounding details scroll view.
Widget buildEmbeddedPosterGrid(
  BuildContext context, {
  required Key key,
  required int itemCount,
  required IndexedWidgetBuilder itemBuilder,
}) {
  final isDesktop = context.isDesktop;
  return Directionality(
    textDirection: TextDirection.rtl,
    child: GridView.builder(
      key: key,
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
          fallback: embeddedPosterGridCrossAxisSpacing,
        ),
        mainAxisSpacing: MultimediaCardLayout.catalogGridMainAxisSpacing(
          context,
          fallback: embeddedPosterGridMainAxisSpacing,
        ),
        handsetPortraitCrossAxisCount:
            MultimediaCardLayout.handsetPortraitGridColumns,
      ),
      itemCount: itemCount,
      itemBuilder: itemBuilder,
    ),
  );
}
