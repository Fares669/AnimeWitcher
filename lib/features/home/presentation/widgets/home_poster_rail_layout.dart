import 'package:flutter/widgets.dart';

import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/multimedia_card.dart';

/// Keeps Home's loading shimmer and its ready poster rails the same size.
({
  double cardWidth,
  double listHeight,
  double spacing,
  double horizontalPadding,
})
homePosterRailLayout(BuildContext context, {required bool isPortrait}) {
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
    isPortrait: isPortrait,
    horizontalPadding: horizontalPadding,
    spacing: spacing,
  );
  return (
    cardWidth: cardWidth,
    listHeight: MultimediaCardLayout.listHeight(
      cardWidth,
      isPortrait: isPortrait,
      isDesktop: isDesktop,
    ),
    spacing: spacing,
    horizontalPadding: horizontalPadding,
  );
}
