import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/core/utils/responsive_breakpoints.dart';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/shared/widgets/desktop_scroll_wrapper.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:animewitcher/shared/widgets/paged_rail.dart';
import 'package:animewitcher/shared/widgets/anime_catalog_shimmer.dart';

class SearchResultSection extends ConsumerStatefulWidget {
  final String providerName;
  final String providerId;
  final List<MultimediaItem> results;
  final bool isLoadingMore;
  final FocusNode? firstCardFocusNode;

  const SearchResultSection({
    super.key,
    required this.providerName,
    required this.providerId,
    required this.results,
    required this.isLoadingMore,
    this.firstCardFocusNode,
  });

  @override
  ConsumerState<SearchResultSection> createState() =>
      _SearchResultSectionState();
}

class _SearchResultSectionState extends ConsumerState<SearchResultSection> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _resultCard(MultimediaItem item, int rIndex, {bool compact = false}) {
    return MultimediaCard.fromItem(
      key: ValueKey(item.url),
      item: item,
      heroTag: 'search_${widget.providerId}_${item.url}_$rIndex',
      compact: compact,
      focusNode: rIndex == 0 ? widget.firstCardFocusNode : null,
      onTap: () {
        if (item.contentType == MultimediaContentType.manga) {
          MangaDetailsRoute(
            $extra: MangaDetailsRouteExtra(item: item),
          ).push<void>(context);
          return;
        }
        DetailsRoute(
          $extra: DetailsRouteExtra(item: item),
        ).push<void>(context);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.results.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    final isLarge =
        ResponsiveBreakpoints.isDesktopPlatform() || context.isTabletOrLarger;
    if (!isLarge) {
      final mobileColumns = context.isHandsetLandscape
          ? ResponsiveBreakpoints.handsetLandscapeAnimeColumns
          : MultimediaCardLayout.handsetPortraitGridColumns;
      final gridPadding = MultimediaCardLayout.catalogGridHorizontalPadding(
        context,
      );
      final crossSpacing = MultimediaCardLayout.catalogGridCrossAxisSpacing(
        context,
      );
      final mainSpacing = MultimediaCardLayout.catalogGridMainAxisSpacing(
        context,
      );
      // Lazy sliver grid, same pattern as View All: only on-screen posters
      // exist, so returning from details remounts a handful of cache hits
      // instead of rebuilding the whole catalog at once.
      return SliverPadding(
        padding: EdgeInsets.fromLTRB(gridPadding, 10, gridPadding, 24),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: mobileColumns,
            crossAxisSpacing: crossSpacing,
            mainAxisSpacing: mainSpacing,
            childAspectRatio: MultimediaCardLayout.portraitGridAspectRatio,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, rIndex) {
              if (rIndex >= widget.results.length) {
                return const AnimePosterShimmer();
              }
              return _resultCard(widget.results[rIndex], rIndex);
            },
            childCount:
                widget.results.length +
                (widget.isLoadingMore ? mobileColumns : 0),
          ),
        ),
      );
    }

    final isLandscape =
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    if (isLandscape) {
      // Adaptive: a 900pt window gets fewer, readable posters while an
      // ultrawide monitor gets more of them at the same physical size,
      // instead of a fixed 8 columns that shrank or ballooned the cards.
      final desktopColumns =
          ResponsiveBreakpoints.desktopLandscapeColumnsForViewport(context);
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: desktopColumns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 14,
            childAspectRatio: MultimediaCardLayout.portraitGridAspectRatio,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, rIndex) {
              if (rIndex >= widget.results.length) {
                return const AnimePosterShimmer();
              }
              return _resultCard(widget.results[rIndex], rIndex, compact: true);
            },
            childCount:
                widget.results.length +
                (widget.isLoadingMore ? desktopColumns : 0),
          ),
        ),
      );
    }

    const listHeight = 350.0;
    const cardWidth = 200.0;
    const spacing = 24.0;
    return SliverToBoxAdapter(
      child: SizedBox(
        height: listHeight,
        child: DesktopScrollWrapper(
          controller: _scrollController,
          child: PagedRail(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            // 200 (card) + 24 (spacing) = 224 snap stride.
            itemExtent: cardWidth + spacing,
            clipBehavior: Clip.none,
            itemCount: widget.results.length + (widget.isLoadingMore ? 3 : 0),
            itemBuilder: (context, rIndex) {
              if (rIndex >= widget.results.length) {
                return Padding(
                  padding: const EdgeInsets.only(right: spacing),
                  child: const AnimePosterShimmer(),
                );
              }

              return Padding(
                padding: const EdgeInsets.only(right: spacing),
                child: _resultCard(widget.results[rIndex], rIndex),
              );
            },
          ),
        ),
      ),
    );
  }
}
