import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/underline_segment_tabs.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/catalog_ltr.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../details/presentation/details_screen.dart';

typedef _RankingPageLoader =
    Future<ProviderMediaPage> Function(
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

class _GlobalStatisticsScreenState extends ConsumerState<GlobalStatisticsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: AnimeWitcherGlobalRanking.values.length,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
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
    return provider.getGlobalRankingPage(ranking, offset: offset, limit: limit);
  }

  bool _isArabic(BuildContext context) =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

  @override
  Widget build(BuildContext context) {
    final accountRevision = ref.watch(accountDataRevisionProvider);
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
                alignment: isArabic
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Directionality(
                  textDirection: isArabic
                      ? TextDirection.rtl
                      : TextDirection.ltr,
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
          _RankingTabs(controller: _tabController, isArabic: isArabic),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                for (
                  var index = 0;
                  index < AnimeWitcherGlobalRanking.values.length;
                  index++
                )
                  LazyTabChild(
                    controller: _tabController,
                    index: index,
                    builder: (context) {
                      final ranking = AnimeWitcherGlobalRanking.values[index];
                      return _RankingPage(
                        key: ValueKey<String>(
                          'global-ranking-page-${ranking.queryType}-$accountRevision',
                        ),
                        ranking: ranking,
                        isArabic: isArabic,
                        loadPage: _loadPage,
                      );
                    },
                  ),
              ],
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
      return _RankingError(isArabic: widget.isArabic, onRetry: _loadInitial);
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

class _RankingTabs extends StatelessWidget {
  const _RankingTabs({required this.controller, required this.isArabic});

  final TabController controller;
  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    const rankings = AnimeWitcherGlobalRanking.values;
    return FilterStyleTabBar(
      controller: controller,
      tabs: [
        for (final ranking in rankings)
          FilterStyleTab(
            label: isArabic ? ranking.arabicTitle : ranking.englishTitle,
          ),
      ],
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
      child: CatalogLtr(
        child: GridView.builder(
          key: PageStorageKey<String>('global-ranking-${ranking.queryType}'),
          controller: controller,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
          gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
            context,
            maxCrossAxisExtent: isDesktop ? 240 : 150,
            childAspectRatio: MultimediaCardLayout.gridAspectRatio(
              isPortrait: true,
              isDesktop: isDesktop,
            ),
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
            return MultimediaCard.fromItem(
              key: ValueKey('${ranking.queryType}-${item.url}'),
              item: item,
              heroTag: 'global-ranking-${ranking.queryType}-${item.id}-$index',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => DetailsScreen(item: item),
                ),
              ),
            );
          },
        ),
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
