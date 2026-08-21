import 'package:flutter/material.dart';

import '../../core/utils/responsive_breakpoints.dart';
import 'shimmer_placeholder.dart';

/// Skeleton poster matching home-page card loading.
class AnimePosterShimmer extends StatelessWidget {
  const AnimePosterShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerPlaceholder.rectangular(borderRadius: 12);
  }
}

/// Full-page anime grid skeleton — same style as the home catalog shimmer.
class AnimeCatalogShimmer extends StatelessWidget {
  const AnimeCatalogShimmer({
    super.key,
    this.itemCount,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 110),
    this.physics = const AlwaysScrollableScrollPhysics(),
  });

  final int? itemCount;
  final EdgeInsetsGeometry padding;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final count = itemCount ?? (isDesktop ? 18 : 12);
    return GridView.builder(
      physics: physics,
      padding: padding,
      gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
        context,
        maxCrossAxisExtent: isDesktop ? 240 : 150,
        childAspectRatio: isDesktop ? 0.58 : 0.55,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: count,
      itemBuilder: (context, index) => const AnimePosterShimmer(),
    );
  }
}
