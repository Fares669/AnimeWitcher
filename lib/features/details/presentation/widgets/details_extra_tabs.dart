import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/account/animewitcher_character_models.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../../../../shared/widgets/underline_segment_tabs.dart';
import 'details_character_rails.dart';
import 'details_poster_grid.dart';

/// Visual RTL order: الشخصيات (right), ذات صلة (center), أنميات مشابهة (left).
const int detailsExtraCharactersTabIndex = 0;
const int detailsExtraRelatedTabIndex = 1;
const int detailsExtraSimilarTabIndex = 2;

class DetailsExtraTabs extends StatefulWidget {
  const DetailsExtraTabs({
    super.key,
    required this.similar,
    required this.related,
    required this.relatedHasMore,
    required this.cast,
    required this.onTabBecameVisible,
    required this.onAnimeTap,
    required this.onCharacterTap,
    this.similarHasMore = false,
    this.onShowMoreSimilar,
    this.onShowMoreRelated,
    this.onShowMoreCharacters,
    this.onRetrySimilar,
    this.onRetryRelated,
    this.onRetryCast,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final AsyncValue<List<MultimediaItem>> similar;
  final AsyncValue<List<MultimediaItem>> related;
  final bool relatedHasMore;
  final bool similarHasMore;
  final AsyncValue<List<Actor>> cast;
  final ValueChanged<int> onTabBecameVisible;
  final void Function(MultimediaItem item) onAnimeTap;
  final void Function(Actor actor) onCharacterTap;
  final VoidCallback? onShowMoreSimilar;
  final VoidCallback? onShowMoreRelated;
  final void Function(String role)? onShowMoreCharacters;
  final VoidCallback? onRetrySimilar;
  final VoidCallback? onRetryRelated;
  final VoidCallback? onRetryCast;
  final EdgeInsetsGeometry contentPadding;

  @override
  State<DetailsExtraTabs> createState() => _DetailsExtraTabsState();
}

class _DetailsExtraTabsState extends State<DetailsExtraTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final Set<int> _visited = <int>{detailsExtraSimilarTabIndex};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: detailsExtraSimilarTabIndex,
    )..addListener(_handleTabTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onTabBecameVisible(detailsExtraSimilarTabIndex);
    });
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabTick)
      ..dispose();
    super.dispose();
  }

  void _handleTabTick() {
    if (_tabController.indexIsChanging) return;
    final index = _tabController.index;
    if (_visited.add(index)) {
      widget.onTabBecameVisible(index);
    }
  }

  /// Characters rails can be taller than the 6-poster similar/related grid.
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
        final tabWidth = constraints.maxWidth / 3;
        final padding = widget.contentPadding.resolve(
          Directionality.of(context),
        );
        final bodyWidth = (constraints.maxWidth - padding.horizontal).clamp(
          0.0,
          double.infinity,
        );
        final gridHeight = detailsExtraTabBodyHeight(context, bodyWidth);
        final bodyHeight = math.max(
          gridHeight,
          _charactersTabBodyHeight(context, gridHeight, maxWidth: bodyWidth),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilterStyleTabBar(
              controller: _tabController,
              isScrollable: false,
              padding: EdgeInsets.zero,
              labelPadding: EdgeInsets.zero,
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: [
                FilterStyleTab(
                  label: animeWitcherCharactersTabLabel,
                  maxWidth: tabWidth,
                ),
                FilterStyleTab(
                  label: animeWitcherRelatedTabLabel,
                  maxWidth: tabWidth,
                ),
                FilterStyleTab(
                  label: animeWitcherSimilarTabLabel,
                  maxWidth: tabWidth,
                ),
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
                      _CharactersTab(
                        state: widget.cast,
                        onCharacterTap: widget.onCharacterTap,
                        onShowMore: widget.onShowMoreCharacters,
                        onRetry: widget.onRetryCast,
                      ),
                      _RelatedTab(
                        state: widget.related,
                        hasMore: widget.relatedHasMore,
                        onItemTap: widget.onAnimeTap,
                        onShowMore: widget.onShowMoreRelated,
                        onRetry: widget.onRetryRelated,
                      ),
                      _SimilarTab(
                        state: widget.similar,
                        hasMore: widget.similarHasMore,
                        onItemTap: widget.onAnimeTap,
                        onShowMore: widget.onShowMoreSimilar,
                        onRetry: widget.onRetrySimilar,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
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

class _RelatedTab extends StatelessWidget {
  const _RelatedTab({
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
      return _ExtraTabMessage(
        message: animeWitcherRelatedErrorMessage,
        onRetry: onRetry,
      );
    }
    final items = state.asData?.value ?? const <MultimediaItem>[];
    if (items.isEmpty) {
      return const _ExtraTabMessage(message: animeWitcherRelatedEmptyMessage);
    }
    final preview = extraTabGridPreview(items, hasMore: hasMore);
    return Align(
      alignment: Alignment.topCenter,
      child: DetailsPosterGrid(
        keyPrefix: 'related',
        items: preview.items,
        showRelationBadge: true,
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
