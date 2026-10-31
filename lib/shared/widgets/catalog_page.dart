import 'package:flutter/material.dart';

import '../../core/utils/responsive_breakpoints.dart';
import 'anime_catalog_shimmer.dart';
import 'app_page_header.dart';
import 'catalog_direction.dart';
import 'mouse_drag_refresh_indicator.dart';
import 'multimedia_card.dart';

/// The shell every catalogue page shares: a transparent app bar over a
/// body, with the header inset computed once and handed to the body
/// builder. Content built from [topInset] can never start up behind
/// the header — the mistake this replaces was each page remembering
/// (or forgetting) the offset on its own.
class CatalogPage extends StatelessWidget {
  const CatalogPage({
    super.key,
    required this.title,
    required this.builder,
    this.onBack,
    this.canPop = true,
    this.background,
  });

  final String title;
  final Widget Function(BuildContext context, double topInset) builder;
  final VoidCallback? onBack;
  final bool canPop;

  /// Painted behind the body, edge to edge (a page gradient, say).
  final Widget? background;

  @override
  Widget build(BuildContext context) {
    final topInset = appPageHeaderContentTopInset(context);
    final body = builder(context, topInset);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(title: title, canPop: canPop, onBack: onBack),
      body: background == null
          ? body
          : Stack(
              fit: StackFit.expand,
              children: [background!, body],
            ),
    );
  }
}

/// The trailing cells a catalogue grid can grow while paging.
enum CatalogFooter { none, loading, retry }

/// The body of a catalogue page: first-load shimmer, an error with a
/// retry, an empty note, and the poster grid — every state placed
/// below [topInset], the grid itself at the catalogue's standard
/// paddings and delegate unless a page overrides its geometry.
class CatalogBody extends StatelessWidget {
  const CatalogBody({
    super.key,
    required this.topInset,
    required this.itemCount,
    required this.itemBuilder,
    this.isLoading = false,
    this.errorMessage,
    this.errorWidget,
    this.onRetry,
    this.emptyMessage,
    this.emptyWidget,
    this.onRefresh,
    this.scrollController,
    this.footer = CatalogFooter.none,
    this.footerCount = 1,
    this.footerBuilder,
    this.characterTiles = false,
    this.isPortrait = true,
    this.maxCrossAxisExtent,
    this.childAspectRatio,
    this.horizontalPadding,
    this.crossAxisSpacing,
    this.mainAxisSpacing,
    this.crossAxisSpacingFallback,
    this.mainAxisSpacingFallback,
    this.handsetPortraitColumns =
        MultimediaCardLayout.handsetPortraitGridColumns,
    this.bottomPadding = 110,
  });

  /// Distance from the top of the screen to below the header.
  final double topInset;

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// First load in flight with nothing to show yet: the shimmer grid.
  final bool isLoading;

  /// First-page failure, shown with [onRetry] when there are no items.
  final String? errorMessage;

  /// A page's own error view, replacing the shared one (it is placed
  /// below the inset; give it no top padding of its own).
  final Widget? errorWidget;
  final Future<void> Function()? onRetry;

  /// Shown when there are no items and nothing failed.
  final String? emptyMessage;
  final Widget? emptyWidget;

  /// Pull-to-refresh for the grid and the empty state.
  final Future<void> Function()? onRefresh;

  final ScrollController? scrollController;

  /// Extra cells after the last item while more pages load or fail.
  final CatalogFooter footer;
  final int footerCount;

  /// Custom footer cell (the index is 0-based within the footer),
  /// taking precedence over [footer]'s built-in cells.
  final Widget Function(BuildContext context, int footerIndex)? footerBuilder;

  /// Character grids: caption-space shimmer and character aspect.
  final bool characterTiles;
  final bool isPortrait;

  /// Grid geometry overrides; null keeps the catalogue standard.
  final double? maxCrossAxisExtent;
  final double? childAspectRatio;
  final double? horizontalPadding;

  /// Precomputed spacings, taking precedence over the fallback-based
  /// catalogue helpers below.
  final double? crossAxisSpacing;
  final double? mainAxisSpacing;
  final double? crossAxisSpacingFallback;
  final double? mainAxisSpacingFallback;
  final int? handsetPortraitColumns;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    if (isLoading && itemCount == 0) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: AnimeCatalogShimmer(characterCaptionSpace: characterTiles),
      );
    }
    if (errorMessage != null && itemCount == 0) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child:
            errorWidget ??
            _CatalogError(message: errorMessage!, onRetry: onRetry),
      );
    }
    // No empty content declared: the grid itself is the empty state
    // (a page still paging its first results in, say).
    if (itemCount == 0 && (emptyMessage != null || emptyWidget != null)) {
      return _empty(context);
    }

    final isDesktop = context.isDesktop;
    final hPad =
        horizontalPadding ??
        MultimediaCardLayout.catalogGridHorizontalPadding(context);
    final grid = CatalogDirection(
      child: GridView.builder(
        controller: scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(hPad, topInset + 16, hPad, bottomPadding),
        gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
          context,
          maxCrossAxisExtent:
              maxCrossAxisExtent ?? (isDesktop ? 240 : 150),
          childAspectRatio:
              childAspectRatio ??
              (characterTiles
                  ? MultimediaCardLayout.characterGridAspectRatio
                  : MultimediaCardLayout.gridAspectRatio(
                      isPortrait: isPortrait,
                      isDesktop: isDesktop,
                    )),
          crossAxisSpacing:
              crossAxisSpacing ??
              MultimediaCardLayout.catalogGridCrossAxisSpacing(
                context,
                fallback: crossAxisSpacingFallback ?? 16,
              ),
          mainAxisSpacing:
              mainAxisSpacing ??
              MultimediaCardLayout.catalogGridMainAxisSpacing(
                context,
                fallback: mainAxisSpacingFallback ?? 16,
              ),
          handsetPortraitCrossAxisCount: handsetPortraitColumns,
          horizontalPadding: hPad,
        ),
        itemCount: itemCount + (footer == CatalogFooter.none ? 0 : footerCount),
        itemBuilder: (context, index) {
          if (index < itemCount) return itemBuilder(context, index);
          final footerIndex = index - itemCount;
          if (footerBuilder != null) return footerBuilder!(context, footerIndex);
          return switch (footer) {
            CatalogFooter.loading => AnimePosterShimmer(
              isPortrait: isPortrait,
              characterCaptionSpace: characterTiles,
            ),
            CatalogFooter.retry => IconButton(
              tooltip: 'إعادة المحاولة',
              onPressed: onRetry == null ? null : () => onRetry!(),
              icon: const Icon(Icons.refresh_rounded),
            ),
            CatalogFooter.none => const SizedBox.shrink(),
          };
        },
      ),
    );
    if (onRefresh == null) return grid;
    return MouseDragRefreshIndicator(onRefresh: onRefresh!, child: grid);
  }

  Widget _empty(BuildContext context) {
    final content = emptyWidget ??
        (emptyMessage == null
            ? const SizedBox.shrink()
            : Text(emptyMessage!));
    if (onRefresh == null) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: Center(child: content),
      );
    }
    return MouseDragRefreshIndicator(
      onRefresh: onRefresh!,
      child: ListView(
        padding: EdgeInsets.only(top: topInset),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.65,
            child: Center(child: content),
          ),
        ],
      ),
    );
  }
}

/// A failed first page: cloud, message, retry — one shape everywhere.
class _CatalogError extends StatelessWidget {
  const _CatalogError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 42),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => onRetry!(),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
