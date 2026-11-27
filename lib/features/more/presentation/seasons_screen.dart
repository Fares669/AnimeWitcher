import 'more_sidebar_shell.dart';

import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:animewitcher/shared/widgets/underline_segment_tabs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/native_provider_resolution.dart';
import '../../../core/utils/offset_pager.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/catalog_direction.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../../shared/widgets/shimmer_placeholder.dart';
import '../../../core/router/app_router.dart';

class SeasonsScreen extends ConsumerStatefulWidget {
  const SeasonsScreen({super.key});

  @override
  ConsumerState<SeasonsScreen> createState() => _SeasonsScreenState();
}

class _SeasonsScreenState extends ConsumerState<SeasonsScreen>
    with SingleTickerProviderStateMixin {
  late Future<_SeasonsBootstrap> _bootstrapFuture;
  late final TabController _tabController;
  int _selectedTab = 1;
  int _reloadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: _selectedTab,
    )..addListener(_handleTabTick);
    _bootstrapFuture = _loadBootstrap();
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabTick)
      ..dispose();
    super.dispose();
  }

  void _handleTabTick() {
    final value = _tabController.index;
    if (value != _selectedTab) {
      setState(() => _selectedTab = value);
    }
  }

  Future<_SeasonsBootstrap> _loadBootstrap() async {
    final active = ref.read(activeProviderProvider);
    final provider = active?.supportsSeasons == true
        ? active
        : ref.nativeProvider;
    if (provider == null) {
      throw StateError('Season catalog provider is unavailable');
    }
    final config = await provider.getSeasonConfig();
    return _SeasonsBootstrap(provider: provider, config: config);
  }

  Future<void> _refreshSeasons({bool waitForArchive = false}) async {
    final future = _loadBootstrap();
    setState(() {
      _reloadGeneration++;
      _bootstrapFuture = future;
    });
    final data = await future;
    if (!waitForArchive || !mounted || !identical(_bootstrapFuture, future)) {
      return;
    }
    try {
      await data.allSeasons;
    } catch (_) {
      // The archive pane presents its own retry state.
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(accountDataRevisionProvider, (previous, next) {
      if (previous == next) return;
      _refreshSeasons().ignore();
    });
    ref.listen(activeProviderProvider, (previous, next) {
      if (previous?.packageName != next?.packageName &&
          (previous?.supportsSeasons == true ||
              next?.supportsSeasons == true)) {
        _refreshSeasons().ignore();
      }
    });

    final embedded = MorePaneScope.of(context);
    final headerTop = appPageHeaderContentTopInset(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: 'المواسم',
        canPop: !embedded && Navigator.of(context).canPop(),
        onBack: () => Navigator.of(context).pop(),
      ),
      body: Padding(
        padding: EdgeInsets.only(top: headerTop),
        child: FutureBuilder<_SeasonsBootstrap>(
          future: _bootstrapFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Column(
                children: [
                  _SeasonTabs(controller: _tabController),
                  Expanded(
                    child: _SeasonsLoadingBody(
                      showSeasonTitle: _selectedTab != 3,
                    ),
                  ),
                ],
              );
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return _LoadError(
                message: 'تعذر تحميل بيانات المواسم',
                onRetry: () {
                  setState(() => _bootstrapFuture = _loadBootstrap());
                },
              );
            }

            final data = snapshot.data!;
            return Column(
              children: [
                _SeasonTabs(controller: _tabController),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      for (var index = 0; index < 4; index++)
                        LazyTabChild(
                          controller: _tabController,
                          index: index,
                          builder: (context) => MouseDragRefreshIndicator(
                            onRefresh: () =>
                                _refreshSeasons(waitForArchive: index == 3),
                            child: _tabBody(data, index),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _tabBody(_SeasonsBootstrap data, int index) {
    switch (index) {
      case 0:
        return _SeasonGrid(
          key: ValueKey('past-${data.config.past}-$_reloadGeneration'),
          catalog: data.catalog(index, data.config.past),
          showSeasonTitle: true,
          emptyLabel: 'لا توجد أعمال في الموسم السابق',
        );
      case 1:
        return _SeasonGrid(
          key: ValueKey('current-${data.config.current}-$_reloadGeneration'),
          catalog: data.catalog(index, data.config.current),
          showSeasonTitle: true,
          emptyLabel: 'لا توجد أعمال في الموسم الحالي',
        );
      case 2:
        return _SeasonGrid(
          key: ValueKey('next-${data.config.next}-$_reloadGeneration'),
          catalog: data.catalog(index, data.config.next),
          showSeasonTitle: true,
          emptyLabel: 'لا توجد أعمال في الموسم القادم',
        );
      default:
        return FutureBuilder<List<String>>(
          key: ValueKey('other-seasons-$_reloadGeneration'),
          future: data.allSeasons,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _SeasonsLoadingBody(showSeasonTitle: false);
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return _LoadError(
                message: 'تعذر تحميل بيانات المواسم',
                onRetry: () => _refreshSeasons(waitForArchive: true).ignore(),
              );
            }
            return _OtherSeasonsList(
              provider: data.provider,
              allSeasons: snapshot.requireData,
            );
          },
        );
    }
  }
}

/// Settings `seasons.past|current|next` string shown as-is above the grid.
class SeasonListTitle extends StatelessWidget {
  const SeasonListTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Align(
        alignment: Alignment.center,
        child: Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

/// Loading counterpart of [SeasonListTitle]. It reserves the same vertical
/// slot so the grid does not jump when the real season/year string arrives.
class SeasonListTitleSkeleton extends StatelessWidget {
  const SeasonListTitleSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleLarge;
    final height = (style?.fontSize ?? 22) * (style?.height ?? 1.2);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Align(
        alignment: Alignment.center,
        child: ShimmerPlaceholder.rectangular(
          key: const ValueKey('season-title-loading-skeleton'),
          width: 156,
          height: height,
          borderRadius: 6,
        ),
      ),
    );
  }
}

class _SeasonsLoadingBody extends StatelessWidget {
  const _SeasonsLoadingBody({required this.showSeasonTitle});

  final bool showSeasonTitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showSeasonTitle) const SeasonListTitleSkeleton(),
        const Expanded(child: AnimeCatalogShimmer()),
      ],
    );
  }
}

class _SeasonsBootstrap {
  final AnimeWitcherProvider provider;
  final ProviderSeasonConfig config;
  // One archive request per exact config/provider generation, on demand.
  late final Future<List<String>> allSeasons = Future<List<String>>.sync(
    () => provider.getAllSeasons(),
  );

  // Retain cheap paging/scroll data, not entire trees of offscreen cards.
  final _catalogs = <int, _SeasonCatalog>{};

  _SeasonCatalog catalog(int tab, String season) =>
      _catalogs.putIfAbsent(tab, () => _SeasonCatalog(provider, season));

  _SeasonsBootstrap({required this.provider, required this.config});
}

class _SeasonTabs extends StatelessWidget {
  final TabController controller;

  const _SeasonTabs({required this.controller});

  @override
  Widget build(BuildContext context) {
    final labels = const <String>[
      'السابق',
      'الحالي',
      'القادم',
      'المواسم الأخرى',
    ];
    const icons = <IconData>[
      Icons.history_rounded,
      Icons.play_circle_outline_rounded,
      Icons.upcoming_outlined,
      Icons.calendar_month_outlined,
    ];
    return FilterStyleTabBar(
      controller: controller,
      tabs: [
        for (var i = 0; i < labels.length; i++)
          FilterStyleTab(label: labels[i], icon: icons[i]),
      ],
    );
  }
}

class _OtherSeasonsList extends StatelessWidget {
  final AnimeWitcherProvider provider;
  final List<String> allSeasons;

  const _OtherSeasonsList({required this.provider, required this.allSeasons});

  Map<int, Map<String, String>> _grouped() {
    final grouped = <int, Map<String, String>>{};
    final pattern = RegExp(r'^(شتاء|ربيع|صيف|خريف)\s+عام\s+(\d{4})$');
    for (final raw in allSeasons) {
      final value = raw.trim();
      final match = pattern.firstMatch(value);
      if (match == null) continue;
      final year = int.tryParse(match.group(2)!);
      final season = match.group(1)!;
      if (year == null) continue;
      grouped.putIfAbsent(year, () => <String, String>{})[season] = value;
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _grouped();
    final years = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    if (years.isEmpty) {
      return Center(child: Text('لا توجد مواسم أخرى'));
    }

    const seasons = <String>['شتاء', 'ربيع', 'صيف', 'خريف'];

    return ListView.separated(
      key: const PageStorageKey<String>('other-seasons'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 110),
      itemCount: years.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: Theme.of(context).dividerColor.withValues(alpha: 0.55),
      ),
      itemBuilder: (context, index) {
        final year = years[index];
        final values = grouped[year]!;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Align(
                alignment: Alignment.center,
                child: Text(
                  '$year',
                  key: ValueKey('other-season-year-$year'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (var i = 0; i < seasons.length; i++) ...[
                    Expanded(
                      child: _SeasonYearButton(
                        label: seasons[i],
                        enabled: values.containsKey(seasons[i]),
                        onTap: () {
                          final fullSeason = values[seasons[i]];
                          if (fullSeason == null) return;
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _SeasonResultsScreen(
                                provider: provider,
                                season: fullSeason,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (i != seasons.length - 1) const SizedBox(width: 8),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SeasonYearButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _SeasonYearButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FilledButton(
      onPressed: enabled ? onTap : null,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 13),
        backgroundColor: colors.primary,
        disabledBackgroundColor: colors.surfaceContainerHighest,
        disabledForegroundColor: colors.onSurfaceVariant.withValues(
          alpha: 0.35,
        ),
        shape: const StadiumBorder(),
      ),
      child: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
    );
  }
}

class _SeasonResultsScreen extends StatefulWidget {
  final AnimeWitcherProvider provider;
  final String season;

  const _SeasonResultsScreen({required this.provider, required this.season});

  @override
  State<_SeasonResultsScreen> createState() => _SeasonResultsScreenState();
}

class _SeasonResultsScreenState extends State<_SeasonResultsScreen> {
  late final _SeasonCatalog _catalog = _SeasonCatalog(
    widget.provider,
    widget.season,
  );

  @override
  Widget build(BuildContext context) {
    final headerTop = appPageHeaderContentTopInset(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppPageAppBar(
        title: widget.season,
        canPop: !MorePaneScope.of(context) && Navigator.of(context).canPop(),
        onBack: () => Navigator.of(context).pop(),
      ),
      body: _SeasonGrid(
        catalog: _catalog,
        topPadding: headerTop,
        emptyLabel: 'لا توجد أعمال في هذا الموسم',
      ),
    );
  }
}

class _SeasonCatalog {
  _SeasonCatalog(this.provider, this.season);

  final AnimeWitcherProvider provider;
  final String season;
  final pager = OffsetPager<MultimediaItem>(keyOf: multimediaItemPageKey);
  double scrollOffset = 0;
  bool requested = false;
  Future<void>? pending;

  Future<void> loadNext() {
    requested = true;
    return pending ??= pager
        .loadNext(
          (offset) => provider
              .getSeasonPage(season, offset: offset, limit: 30)
              .then(
                (page) => (
                  items: page.items,
                  nextOffset: page.nextOffset,
                  hasMore: page.hasMore,
                ),
              ),
        )
        .whenComplete(() {
          pending = null;
        });
  }
}

class _SeasonGrid extends StatefulWidget {
  final _SeasonCatalog catalog;
  final double topPadding;
  final String emptyLabel;
  final bool showSeasonTitle;

  const _SeasonGrid({
    super.key,
    required this.catalog,
    this.topPadding = 0,
    required this.emptyLabel,
    this.showSeasonTitle = false,
  });

  @override
  State<_SeasonGrid> createState() => _SeasonGridState();
}

class _SeasonGridState extends State<_SeasonGrid> {
  late final ScrollController _controller = ScrollController(
    initialScrollOffset: widget.catalog.scrollOffset,
    keepScrollOffset: false,
  );

  OffsetPager<MultimediaItem> get _pager => widget.catalog.pager;
  String get _season => widget.catalog.season;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    if (widget.catalog.pending case final pending?) {
      // The previous grid may have left the viewport during a page request.
      _redrawWhenLoaded(pending);
    } else if (!widget.catalog.requested) {
      _loadNext();
    }
  }

  void _onScroll() {
    if (_controller.hasClients) {
      widget.catalog.scrollOffset = _controller.position.pixels;
    }
    if (_pager.shouldLoadMore(_controller)) _loadNext();
  }

  Future<void> _loadNext() async {
    if (_pager.loading || !_pager.hasMore || _season.trim().isEmpty) return;
    final future = widget.catalog.loadNext();
    setState(() {});
    await _redrawWhenLoaded(future);
  }

  Future<void> _redrawWhenLoaded(Future<void> future) async {
    await future;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final initialLoading = _pager.items.isEmpty && _pager.loading;
    final extra = _pager.loading
        ? AnimeCatalogShimmer.loadMoreCount
        : (_pager.error != null && _pager.hasMore ? 1 : 0);
    return CatalogDirection(
      child: CustomScrollView(
        controller: _controller,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (widget.showSeasonTitle && _season.trim().isNotEmpty)
            SliverToBoxAdapter(child: SeasonListTitle(title: _season)),
          if (_pager.items.isEmpty && !initialLoading)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _pager.error != null
                  ? _LoadError(message: widget.emptyLabel, onRetry: _loadNext)
                  : Center(child: Text(widget.emptyLabel)),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                MultimediaCardLayout.catalogGridHorizontalPadding(context),
                (initialLoading ? 0 : widget.topPadding) + 16,
                MultimediaCardLayout.catalogGridHorizontalPadding(context),
                110,
              ),
              sliver: SliverGrid(
                gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
                  context,
                  maxCrossAxisExtent: isDesktop ? 240 : 150,
                  childAspectRatio: MultimediaCardLayout.gridAspectRatio(
                    isPortrait: true,
                    isDesktop: isDesktop,
                  ),
                  crossAxisSpacing:
                      MultimediaCardLayout.catalogGridCrossAxisSpacing(context),
                  mainAxisSpacing:
                      MultimediaCardLayout.catalogGridMainAxisSpacing(context),
                  handsetPortraitCrossAxisCount:
                      MultimediaCardLayout.handsetPortraitGridColumns,
                  horizontalPadding:
                      MultimediaCardLayout.catalogGridHorizontalPadding(
                        context,
                      ),
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (initialLoading) {
                      return const RepaintBoundary(child: AnimePosterShimmer());
                    }
                    if (index >= _pager.items.length) {
                      if (_pager.error != null) {
                        return IconButton(
                          tooltip: 'إعادة المحاولة',
                          onPressed: _loadNext,
                          icon: const Icon(Icons.refresh_rounded),
                        );
                      }
                      return const RepaintBoundary(child: AnimePosterShimmer());
                    }
                    final item = _pager.items[index];
                    return MultimediaCard.fromItem(
                      key: ValueKey('season-$_season-${item.url}'),
                      item: item,
                      heroTag: heroTagWithId(
                        'season-$_season',
                        item,
                        index,
                        dashed: true,
                      ),
                      onTap: () => item.openDetails(context),
                    );
                  },
                  // MultimediaCard is already a repaint boundary.
                  addRepaintBoundaries: false,
                  childCount: initialLoading
                      ? (isDesktop ? 18 : 12)
                      : _pager.items.length + extra,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _LoadError({required this.message, required this.onRetry});

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
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}
