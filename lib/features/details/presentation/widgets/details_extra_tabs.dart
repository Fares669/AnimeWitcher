import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/account/animewitcher_character_models.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../../../../shared/widgets/underline_segment_tabs.dart';
import 'details_character_rails.dart';
import 'details_poster_grid.dart';

/// Visual RTL order: أنميات مشابهة (right), الشخصيات (left). The related
/// titles live in the seasons bar above the episodes now, so no tab of their
/// own.
const int detailsExtraSimilarTabIndex = 0;
const int detailsExtraCharactersTabIndex = 1;

class DetailsExtraTabs extends StatefulWidget {
  const DetailsExtraTabs({
    super.key,
    required this.similar,
    required this.cast,
    required this.onTabBecameVisible,
    required this.onAnimeTap,
    required this.onCharacterTap,
    this.similarHasMore = false,
    this.onShowMoreSimilar,
    this.onShowMoreCharacters,
    this.onRetrySimilar,
    this.onRetryCast,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final AsyncValue<List<MultimediaItem>> similar;
  final bool similarHasMore;
  final AsyncValue<List<Actor>> cast;
  final ValueChanged<int> onTabBecameVisible;
  final void Function(MultimediaItem item) onAnimeTap;
  final void Function(Actor actor) onCharacterTap;
  final VoidCallback? onShowMoreSimilar;
  final void Function(String role)? onShowMoreCharacters;
  final VoidCallback? onRetrySimilar;
  final VoidCallback? onRetryCast;
  final EdgeInsetsGeometry contentPadding;

  @override
  State<DetailsExtraTabs> createState() => _DetailsExtraTabsState();
}

class _DetailsExtraTabsState extends State<DetailsExtraTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final Set<int> _visited = <int>{};
  ScrollPosition? _scrollPosition;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: detailsExtraSimilarTabIndex,
    )..addListener(_handleTabTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifySimilarIfOnScreen();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (identical(position, _scrollPosition)) return;
    _scrollPosition?.removeListener(_handleScroll);
    _scrollPosition = position;
    _scrollPosition?.addListener(_handleScroll);
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_handleScroll);
    _tabController
      ..removeListener(_handleTabTick)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() => _notifySimilarIfOnScreen();

  void _handleTabTick() {
    if (_tabController.indexIsChanging) return;
    // The body is as tall as the tab being read, so a change of tab is a
    // change of height.
    if (mounted) setState(() {});
    _notifyTab(_tabController.index);
  }

  /// Similar is the default extra tab, but the details page builds this
  /// section below the hero even when it is off-screen. Fetch Algolia
  /// `series_similar` only once the rail is actually in the viewport.
  void _notifySimilarIfOnScreen() {
    if (_visited.contains(detailsExtraSimilarTabIndex)) return;
    if (_tabController.index != detailsExtraSimilarTabIndex) return;
    if (!_isSectionOnScreen()) return;
    _notifyTab(detailsExtraSimilarTabIndex);
  }

  bool _isSectionOnScreen() {
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.hasSize || !object.attached) {
      return false;
    }

    // Sliver viewports do not always apply their scroll offset to
    // [RenderBox.localToGlobal]. Use the viewport reveal offset instead.
    final viewport = RenderAbstractViewport.maybeOf(object);
    final position = Scrollable.maybeOf(context)?.position;
    if (viewport != null && position != null && position.hasPixels) {
      final leading = viewport.getOffsetToReveal(object, 0).offset;
      final trailing = leading + object.size.height;
      final viewStart = position.pixels;
      final viewEnd = viewStart + position.viewportDimension;
      return leading < viewEnd && trailing > viewStart;
    }

    final section = object.localToGlobal(Offset.zero) & object.size;
    if (section.isEmpty) return false;
    return section.overlaps(Offset.zero & MediaQuery.sizeOf(context));
  }

  void _notifyTab(int index) {
    if (!_visited.add(index)) return;
    widget.onTabBecameVisible(index);
  }

  /// Characters rails can be taller than the 6-poster similar grid.
  /// Size the shared [TabBarView] to the taller tab so characters never get
  /// their own vertical scroll inside the details page.
  double _charactersTabBodyHeight(
    BuildContext context,
    double gridHeight, {
    required double maxWidth,
  }) {
    final cast = widget.cast.asData?.value;
    if (cast == null || cast.isEmpty) return gridHeight;
    final hasMain = DetailsCharacterRails.mainCast(cast).isNotEmpty;
    final hasSupporting = DetailsCharacterRails.supportingCast(cast).isNotEmpty;
    if (!hasMain && !hasSupporting) return gridHeight;
    return detailsCharacterRailsHeight(
      context,
      hasMain: hasMain,
      hasSupporting: hasSupporting,
      maxWidth: maxWidth,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = widget.contentPadding.resolve(
          Directionality.of(context),
        );
        final bodyWidth = (constraints.maxWidth - padding.horizontal).clamp(
          0.0,
          double.infinity,
        );
        // Room for the rows the tab on screen actually fills. These grids
        // show at most six slots, so on a wide window that is one row, and
        // reserving two left a poster's height of nothing underneath.
        final columns = detailsExtraTabRenderedColumns(context, bodyWidth);
        final tabItems = widget.similar.asData?.value.length ?? 0;
        final hasMore = widget.similarHasMore;
        final slots = tabItems == 0
            ? animeWitcherExtraTabPreviewSlots
            : (hasMore || tabItems > animeWitcherExtraTabPreviewSlots
                      ? animeWitcherExtraTabPreviewItemsWhenMore + 1
                      : tabItems)
                  .clamp(1, animeWitcherExtraTabPreviewSlots);
        final rows = (slots / columns).ceil().clamp(1, 2);
        final gridHeight = detailsExtraTabBodyHeight(
          context,
          bodyWidth,
          rows: rows,
        );
        // The height of the tab on screen, not of the taller of the two.
        // Sized to the tallest, a page whose characters fill two rails left
        // that much empty room under a single row of similar anime, and
        // everything below — the comments — sat a screen further down than
        // it looked like it should.
        final bodyHeight =
            _tabController.index == detailsExtraCharactersTabIndex
            ? _charactersTabBodyHeight(context, gridHeight, maxWidth: bodyWidth)
            : gridHeight;
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilterStyleTabBar(
                controller: _tabController,
                isScrollable: false,
                padding: EdgeInsets.zero,
                onTap: _notifyTab,
                tabs: const [
                  FilterStyleTab(label: animeWitcherSimilarTabLabel),
                  FilterStyleTab(label: animeWitcherCharactersTabLabel),
                ],
              ),
              const SizedBox(height: 16),
              Padding(
                padding: widget.contentPadding,
                child: SizedBox(
                  height: bodyHeight,
                  child: _NestedExtraTabPager(
                    child: TabBarView(
                      key: const ValueKey('details-extra-tab-view'),
                      controller: _tabController,
                      children: [
                        _SimilarTab(
                          state: widget.similar,
                          hasMore: widget.similarHasMore,
                          onItemTap: widget.onAnimeTap,
                          onShowMore: widget.onShowMoreSimilar,
                          onRetry: widget.onRetrySimilar,
                        ),
                        _CharactersTab(
                          state: widget.cast,
                          onCharacterTap: widget.onCharacterTap,
                          onShowMore: widget.onShowMoreCharacters,
                          onRetry: widget.onRetryCast,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Absorbs horizontal overscroll so a nested extra-tabs [TabBarView]
/// does not hand the gesture to the parent details/episodes pager.
class _NestedExtraTabPager extends StatelessWidget {
  const _NestedExtraTabPager({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        return notification.metrics.axis == Axis.horizontal;
      },
      child: child,
    );
  }
}

class _SimilarTab extends StatelessWidget {
  const _SimilarTab({
    required this.state,
    required this.hasMore,
    required this.onItemTap,
    this.onShowMore,
    this.onRetry,
  });

  final AsyncValue<List<MultimediaItem>> state;
  final bool hasMore;
  final void Function(MultimediaItem item) onItemTap;
  final VoidCallback? onShowMore;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (state.isLoading) return const _ExtraTabLoading();
    if (state.hasError) {
      final error = state.error;
      final message = error is AnimeWitcherSearchDisabledException
          ? error.message
          : animeWitcherSimilarSearchDisabledMessage;
      return _ExtraTabMessage(
        message: message,
        onRetry: error is AnimeWitcherSearchDisabledException ? null : onRetry,
      );
    }
    final items = state.asData?.value ?? const <MultimediaItem>[];
    if (items.isEmpty) {
      return const _ExtraTabMessage(message: animeWitcherSimilarEmptyMessage);
    }
    final preview = extraTabGridPreview(items, hasMore: hasMore);
    return Align(
      alignment: Alignment.topCenter,
      child: DetailsPosterGrid(
        keyPrefix: 'similar',
        items: preview.items,
        hasMore: preview.showMore,
        onShowMore: onShowMore,
        onItemTap: onItemTap,
      ),
    );
  }
}

class _CharactersTab extends StatelessWidget {
  const _CharactersTab({
    required this.state,
    required this.onCharacterTap,
    this.onShowMore,
    this.onRetry,
  });

  final AsyncValue<List<Actor>> state;
  final void Function(Actor actor) onCharacterTap;
  final void Function(String role)? onShowMore;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (state.isLoading) return const _ExtraTabLoading();
    if (state.hasError) {
      return _ExtraTabMessage(
        message: animeWitcherCharactersDataEmptyMessage,
        onRetry: onRetry,
      );
    }
    final cast = state.asData?.value ?? const <Actor>[];
    if (cast.isEmpty) {
      return const _ExtraTabMessage(
        message: animeWitcherCharactersEmptyMessage,
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: DetailsCharacterRails(
        cast: cast,
        onCharacterTap: onCharacterTap,
        onShowMore: onShowMore,
      ),
    );
  }
}

class _ExtraTabLoading extends StatelessWidget {
  const _ExtraTabLoading();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand(child: Center(child: AppLoadingIndicator()));
  }
}

class _ExtraTabMessage extends StatelessWidget {
  const _ExtraTabMessage({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
