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
  final AsyncValue<List<Actor>> cast;
  final ValueChanged<int> onTabBecameVisible;
  final void Function(MultimediaItem item) onAnimeTap;
  final void Function(Actor actor) onCharacterTap;
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
    final isNew = _visited.add(index);
    if (isNew) {
      widget.onTabBecameVisible(index);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final tabWidth = constraints.maxWidth / 3;
            return FilterStyleTabBar(
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
            );
          },
        ),
        const SizedBox(height: 16),
        Padding(
          padding: widget.contentPadding,
          child: _buildBody(),
        ),
      ],
    );
  }

  Widget _buildBody() {
    switch (_tabController.index) {
      case detailsExtraCharactersTabIndex:
        return _CharactersTab(
          state: widget.cast,
          onCharacterTap: widget.onCharacterTap,
          onShowMore: widget.onShowMoreCharacters,
          onRetry: widget.onRetryCast,
        );
      case detailsExtraRelatedTabIndex:
        return _RelatedTab(
          state: widget.related,
          hasMore: widget.relatedHasMore,
          onItemTap: widget.onAnimeTap,
          onShowMore: widget.onShowMoreRelated,
          onRetry: widget.onRetryRelated,
        );
      default:
        return _SimilarTab(
          state: widget.similar,
          onItemTap: widget.onAnimeTap,
          onRetry: widget.onRetrySimilar,
        );
    }
  }
}

class _SimilarTab extends StatelessWidget {
  const _SimilarTab({
    required this.state,
    required this.onItemTap,
    this.onRetry,
  });

  final AsyncValue<List<MultimediaItem>> state;
  final void Function(MultimediaItem item) onItemTap;
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
    return DetailsPosterGrid(
      keyPrefix: 'similar',
      items: items,
      onItemTap: onItemTap,
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
    return DetailsPosterGrid(
      keyPrefix: 'related',
      items: items,
      showRelationBadge: true,
      hasMore: hasMore,
      onShowMore: onShowMore,
      onItemTap: onItemTap,
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
    return DetailsCharacterRails(
      cast: cast,
      onCharacterTap: onCharacterTap,
      onShowMore: onShowMore,
    );
  }
}

class _ExtraTabLoading extends StatelessWidget {
  const _ExtraTabLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 36),
      child: Center(child: AppLoadingIndicator()),
    );
  }
}

class _ExtraTabMessage extends StatelessWidget {
  const _ExtraTabMessage({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
      child: Column(
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
    );
  }
}
