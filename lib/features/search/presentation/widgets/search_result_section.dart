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
      heroTag: heroTagWithUrl('search_${widget.providerId}', item, rIndex),
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
    if (!isLarge ||
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height) {
      // Wide windows choose adaptive columns; handsets keep their own
      // portrait and landscape grid metrics.
      final columns = isLarge
          ? ResponsiveBreakpoints.desktopLandscapeColumnsForViewport(context)
          : context.isHandsetLandscape
          ? ResponsiveBreakpoints.handsetLandscapeAnimeColumns
          : MultimediaCardLayout.handsetPortraitGridColumns;
      final EdgeInsets padding;
      if (isLarge) {
        padding = const EdgeInsets.fromLTRB(16, 10, 16, 24);
      } else {
        final side = MultimediaCardLayout.catalogGridHorizontalPadding(context);
        padding = EdgeInsets.fromLTRB(side, 10, side, 24);
      }
      final crossSpacing = isLarge
          ? 12.0
          : MultimediaCardLayout.catalogGridCrossAxisSpacing(context);
      final mainSpacing = isLarge
          ? 14.0
          : MultimediaCardLayout.catalogGridMainAxisSpacing(context);
      // Lazy grid: only the visible posters need to rebuild on route return.
      return SliverPadding(
        padding: padding,
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: crossSpacing,
            mainAxisSpacing: mainSpacing,
            childAspectRatio: MultimediaCardLayout.portraitGridAspectRatio,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, rIndex) {
              if (rIndex >= widget.results.length) {
                return const RepaintBoundary(child: AnimePosterShimmer());
              }
              return _resultCard(
                widget.results[rIndex],
                rIndex,
                compact: isLarge,
              );
            },
            // MultimediaCard already owns a boundary; keep one for shimmers
            // above without adding a second boundary to every real card.
            addRepaintBoundaries: false,
            childCount:
                widget.results.length + (widget.isLoadingMore ? columns : 0),
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
