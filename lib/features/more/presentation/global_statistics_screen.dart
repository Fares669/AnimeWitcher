import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/shared/widgets/apple_liquid_glass.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../details/presentation/details_screen.dart';

typedef _RankingPageLoader = Future<ProviderMediaPage> Function(
  AnimeWitcherGlobalRanking ranking, {
  required int offset,
  required int limit,
});

class GlobalStatisticsScreen extends ConsumerStatefulWidget {
  const GlobalStatisticsScreen({super.key});

  @override
  ConsumerState<GlobalStatisticsScreen> createState() =>
      _GlobalStatisticsScreenState();
}

class _GlobalStatisticsScreenState
    extends ConsumerState<GlobalStatisticsScreen> {
  late final PageController _pageController;
  int _selectedRanking = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  AnimeWitcherNativeProvider? _provider() {
    final active = ref.read(activeProviderProvider);
    if (active is AnimeWitcherNativeProvider) return active;
    for (final provider in ref.read(extensionManagerProvider)) {
      if (provider is AnimeWitcherNativeProvider) return provider;
    }
    return null;
  }

  Future<ProviderMediaPage> _loadPage(
    AnimeWitcherGlobalRanking ranking, {
    required int offset,
    required int limit,
  }) {
    final provider = _provider();
    if (provider == null) {
      return Future<ProviderMediaPage>.error(
        StateError('AnimeWitcher Native provider is unavailable'),
      );
    }
    return provider.getGlobalRankingPage(
      ranking,
      offset: offset,
      limit: limit,
    );
  }

  void _selectRanking(int value) {
    if (value < 0 ||
        value >= AnimeWitcherGlobalRanking.values.length ||
        value == _selectedRanking) {
      return;
    }
    setState(() => _selectedRanking = value);
    _pageController.animateToPage(
      value,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  bool _isArabic(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  @override
  Widget build(BuildContext context) {
    final isArabic = _isArabic(context);
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppBar(
            automaticallyImplyLeading: false,
            centerTitle: false,
            titleSpacing: 16,
            title: ApplePersistentGlassHeaderScope(
              enabled: Navigator.of(context).canPop(),
              onBack: () => Navigator.of(context).pop(),
              child: Align(
                alignment:
                    isArabic ? Alignment.centerRight : Alignment.centerLeft,
                child: Directionality(
                  textDirection:
                      isArabic ? TextDirection.rtl : TextDirection.ltr,
                  child: Text(
                    isArabic ? 'الإحصائيات العالمية' : 'Global statistics',
                  ),
                ),
              ),
            ),
            leading: appleUsesPersistentLiquidGlassHeader
                ? null
                : AppleLiquidGlassBackButton(
                    onPressed: () => Navigator.of(context).pop(),
                  ),
            elevation: 0,
          ),
        ),
      ),
      body: Column(
        children: [
          _RankingTabs(
            selectedIndex: _selectedRanking,
            isArabic: isArabic,
            onSelected: _selectRanking,
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: AnimeWitcherGlobalRanking.values.length,
              onPageChanged: (value) {
                if (value != _selectedRanking) {
                  setState(() => _selectedRanking = value);
                }
              },
              itemBuilder: (context, index) {
                final ranking = AnimeWitcherGlobalRanking.values[index];
                return _RankingPage(
                  key: PageStorageKey<String>(
                    'global-ranking-page-${ranking.queryType}',
                  ),
                  ranking: ranking,
                  isArabic: isArabic,
                  loadPage: _loadPage,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RankingPage extends StatefulWidget {
  const _RankingPage({
    super.key,
    required this.ranking,
    required this.isArabic,
    required this.loadPage,
  });

  final AnimeWitcherGlobalRanking ranking;
  final bool isArabic;
  final _RankingPageLoader loadPage;

  @override
  State<_RankingPage> createState() => _RankingPageState();
}

class _RankingPageState extends State<_RankingPage>
    with AutomaticKeepAliveClientMixin<_RankingPage> {
  static const int _pageSize = 30;
  static const double _loadMoreThreshold = 900;

  final ScrollController _scrollController = ScrollController();
  final List<MultimediaItem> _items = <MultimediaItem>[];
  int _nextOffset = 0;
  bool _hasMore = true;
  bool _initialLoading = true;
  bool _loadingMore = false;
  Object? _initialError;
  Object? _loadMoreError;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  String _itemKey(MultimediaItem item) {
    final url = item.url.trim();
    if (url.isNotEmpty) return url;
    return '${item.id}|${item.title}';
  }

  void _replaceItems(List<MultimediaItem> incoming) {
    _items
      ..clear()
      ..addAll(incoming);
  }

  void _appendItems(List<MultimediaItem> incoming) {
    final existing = _items.map(_itemKey).toSet();
    for (final item in incoming) {
      if (existing.add(_itemKey(item))) _items.add(item);
    }
  }

  Future<void> _loadInitial() async {
    if (mounted) {
      setState(() {
        _initialLoading = true;
        _initialError = null;
        _loadMoreError = null;
      });
    }
    try {
      final page = await widget.loadPage(
        widget.ranking,
        offset: 0,
        limit: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _replaceItems(page.items);
        _nextOffset = page.nextOffset;
        _hasMore = page.hasMore && page.nextOffset > 0;
        _initialLoading = false;
      });
      _maybeFillViewport();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _initialLoading = false;
        _initialError = error;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_initialLoading || _loadingMore || !_hasMore) return;
    final requestedOffset = _nextOffset;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final page = await widget.loadPage(
        widget.ranking,
        offset: requestedOffset,
        limit: _pageSize,
      );
      if (!mounted) return;
      final nextOffset = page.nextOffset > requestedOffset
          ? page.nextOffset
          : requestedOffset + _pageSize;
      setState(() {
        _appendItems(page.items);
        _nextOffset = nextOffset;
        _hasMore = page.hasMore && page.nextOffset > requestedOffset;
        _loadingMore = false;
      });
      _maybeFillViewport();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = error;
      });
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients || !_hasMore || _loadingMore) return;
    if (_scrollController.position.extentAfter <= _loadMoreThreshold) {
      _loadMore();
    }
  }

  void _maybeFillViewport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_hasMore ||
          _initialLoading ||
          _loadingMore ||
          !_scrollController.hasClients) {
        return;
      }
      if (_scrollController.position.maxScrollExtent < _loadMoreThreshold) {
        _loadMore();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_initialLoading && _items.isEmpty) {
      return const AnimeCatalogShimmer();
    }
    if (_initialError != null && _items.isEmpty) {
      return _RankingError(
        isArabic: widget.isArabic,
        onRetry: _loadInitial,
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadInitial,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.55,
              child: Center(
                child: Text(
                  widget.isArabic
                      ? 'لا توجد نتائج في هذا التصنيف حاليًا'
                      : 'No results in this ranking right now',
                ),
              ),
            ),
          ],
        ),
      );
    }

    return _RankingGrid(
      controller: _scrollController,
      items: _items,
      ranking: widget.ranking,
      isArabic: widget.isArabic,
      loadingMore: _loadingMore,
      loadMoreError: _loadMoreError != null,
      onLoadMoreRetry: _loadMore,
      onRefresh: _loadInitial,
    );
  }
}

class _RankingTabs extends StatefulWidget {
  const _RankingTabs({
    required this.selectedIndex,
    required this.isArabic,
    required this.onSelected,
  });

  final int selectedIndex;
  final bool isArabic;
  final ValueChanged<int> onSelected;

  @override
  State<_RankingTabs> createState() => _RankingTabsState();
}

class _RankingTabsState extends State<_RankingTabs> {
  final GlobalKey _viewportKey = GlobalKey();
  late final List<GlobalKey> _rankingKeys = List<GlobalKey>.generate(
    AnimeWitcherGlobalRanking.values.length,
    (_) => GlobalKey(),
  );
  bool _visibilityCheckScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleSelectedRankingVisibility();
  }

  @override
  void didUpdateWidget(covariant _RankingTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex ||
        oldWidget.isArabic != widget.isArabic) {
      _scheduleSelectedRankingVisibility();
    }
  }

  void _scheduleSelectedRankingVisibility() {
    if (_visibilityCheckScheduled) return;
    _visibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckScheduled = false;
      if (!mounted) return;
      _revealSelectedRankingIfNeeded();
    });
  }

  void _revealSelectedRankingIfNeeded() {
    final index = widget.selectedIndex;
    if (index < 0 || index >= _rankingKeys.length) return;

    final viewportContext = _viewportKey.currentContext;
    final rankingContext = _rankingKeys[index].currentContext;
    final viewportBox = viewportContext?.findRenderObject();
    final rankingBox = rankingContext?.findRenderObject();
    if (viewportBox is! RenderBox ||
        rankingBox is! RenderBox ||
        !viewportBox.hasSize ||
        !rankingBox.hasSize ||
        rankingContext == null) {
      return;
    }

    final viewportOrigin = viewportBox.localToGlobal(Offset.zero);
    final rankingOrigin = rankingBox.localToGlobal(Offset.zero);
    final viewportLeft = viewportOrigin.dx + 4;
    final viewportRight = viewportOrigin.dx + viewportBox.size.width - 4;
    final rankingLeft = rankingOrigin.dx;
    final rankingRight = rankingOrigin.dx + rankingBox.size.width;
    if (rankingLeft >= viewportLeft && rankingRight <= viewportRight) return;

    unawaited(
      Scrollable.ensureVisible(
        rankingContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rankings = AnimeWitcherGlobalRanking.values;
    return SingleChildScrollView(
      key: _viewportKey,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          for (var i = 0; i < rankings.length; i++) ...[
            Material(
              key: _rankingKeys[i],
              color: widget.selectedIndex == i
                  ? colors.primary
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(24),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => widget.onSelected(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 11,
                  ),
                  child: Text(
                    widget.isArabic
                        ? rankings[i].arabicTitle
                        : rankings[i].englishTitle,
                    style: TextStyle(
                      color: widget.selectedIndex == i
                          ? colors.onPrimary
                          : colors.onSurface,
                      fontWeight: widget.selectedIndex == i
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
            if (i != rankings.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _RankingGrid extends StatelessWidget {
  const _RankingGrid({
    required this.controller,
    required this.items,
    required this.ranking,
    required this.isArabic,
    required this.loadingMore,
    required this.loadMoreError,
    required this.onLoadMoreRetry,
    required this.onRefresh,
  });

  final ScrollController controller;
  final List<MultimediaItem> items;
  final AnimeWitcherGlobalRanking ranking;
  final bool isArabic;
  final bool loadingMore;
  final bool loadMoreError;
  final Future<void> Function() onLoadMoreRetry;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final hasFooter = loadingMore || loadMoreError;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: GridView.builder(
        key: PageStorageKey<String>('global-ranking-${ranking.queryType}'),
        controller: controller,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
        gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
          context,
          maxCrossAxisExtent: isDesktop ? 240 : 150,
          childAspectRatio: isDesktop ? 0.58 : 0.55,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: items.length + (hasFooter ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= items.length) {
            if (loadingMore) {
              return const AnimePosterShimmer();
            }
            return Center(
              child: TextButton.icon(
                onPressed: () => onLoadMoreRetry(),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(isArabic ? 'إعادة المحاولة' : 'Retry'),
              ),
            );
          }
          final item = items[index];
          return MultimediaCard(
            key: ValueKey('${ranking.queryType}-${item.url}'),
            imageUrl: item.posterImageUrl,
            title: item.title,
            heroTag: 'global-ranking-${ranking.queryType}-${item.id}-$index',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DetailsScreen(item: item),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RankingError extends StatelessWidget {
  const _RankingError({required this.isArabic, required this.onRetry});

  final bool isArabic;
  final Future<void> Function() onRetry;

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
            Text(
              isArabic
                  ? 'تعذر تحميل هذا التصنيف'
                  : 'Could not load this ranking',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () => onRetry(),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(isArabic ? 'إعادة المحاولة' : 'Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
