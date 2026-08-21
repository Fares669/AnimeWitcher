import 'package:flutter/material.dart';
import 'package:skystream/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../details/presentation/details_screen.dart';

class SeasonsScreen extends ConsumerStatefulWidget {
  const SeasonsScreen({super.key});

  @override
  ConsumerState<SeasonsScreen> createState() => _SeasonsScreenState();
}

class _SeasonsScreenState extends ConsumerState<SeasonsScreen> {
  late Future<_SeasonsBootstrap> _bootstrapFuture;
  late final PageController _pageController;
  int _selectedTab = 1;
  int _reloadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _selectedTab);
    _bootstrapFuture = _loadBootstrap();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _selectTab(int value) {
    if (value < 0 || value > 3 || value == _selectedTab) return;
    setState(() => _selectedTab = value);
    _pageController.animateToPage(
      value,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }
  AnimeWitcherNativeProvider? _provider() {
    final active = ref.read(activeProviderProvider);
    if (active is AnimeWitcherNativeProvider) return active;
    for (final provider in ref.read(extensionManagerProvider)) {
      if (provider is AnimeWitcherNativeProvider) return provider;
    }
    return null;
  }

  Future<_SeasonsBootstrap> _loadBootstrap() async {
    final provider = _provider();
    if (provider == null) {
      throw StateError('AnimeWitcher Native provider is unavailable');
    }
    final config = await provider.getSeasonConfig();
    final allSeasons = await provider.getAllSeasons();
    return _SeasonsBootstrap(
      provider: provider,
      config: config,
      allSeasons: allSeasons,
    );
  }

  Future<void> _refreshSeasons() async {
    final future = _loadBootstrap();
    setState(() {
      _reloadGeneration++;
      _bootstrapFuture = future;
    });
    await future;
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
                  child: Text(isArabic ? 'المواسم' : 'Seasons'),
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
      body: FutureBuilder<_SeasonsBootstrap>(
        future: _bootstrapFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const AnimeCatalogShimmer();
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return _LoadError(
              message: isArabic
                  ? 'تعذر تحميل بيانات المواسم'
                  : 'Could not load season data',
              onRetry: () {
                setState(() => _bootstrapFuture = _loadBootstrap());
              },
            );
          }

          final data = snapshot.data!;
          return Column(
            children: [
              _SeasonTabs(
                selectedIndex: _selectedTab,
                isArabic: isArabic,
                onSelected: _selectTab,
              ),
              Divider(height: 1, color: Theme.of(context).dividerColor),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: 4,
                  onPageChanged: (value) {
                    if (value != _selectedTab) {
                      setState(() => _selectedTab = value);
                    }
                  },
                  itemBuilder: (context, index) => RefreshIndicator(
                    onRefresh: _refreshSeasons,
                    child: _tabBody(data, isArabic, index),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tabBody(_SeasonsBootstrap data, bool isArabic, int index) {
    switch (index) {
      case 0:
        return _SeasonGrid(
          key: ValueKey('past-${data.config.past}-$_reloadGeneration'),
          provider: data.provider,
          season: data.config.past,
          emptyLabel: isArabic
              ? 'لا توجد أعمال في الموسم السابق'
              : 'No titles in the previous season',
        );
      case 1:
        return _SeasonGrid(
          key: ValueKey('current-${data.config.current}-$_reloadGeneration'),
          provider: data.provider,
          season: data.config.current,
          emptyLabel: isArabic
              ? 'لا توجد أعمال في الموسم الحالي'
              : 'No titles in the current season',
        );
      case 2:
        return _SeasonGrid(
          key: ValueKey('next-${data.config.next}-$_reloadGeneration'),
          provider: data.provider,
          season: data.config.next,
          emptyLabel: isArabic
              ? 'لا توجد أعمال في الموسم القادم'
              : 'No titles in the next season',
        );
      default:
        return _OtherSeasonsList(
          key: ValueKey('other-seasons-$_reloadGeneration'),
          provider: data.provider,
          allSeasons: data.allSeasons,
          isArabic: isArabic,
        );
    }
  }
}

class _SeasonsBootstrap {
  final AnimeWitcherNativeProvider provider;
  final AnimeWitcherSeasonConfig config;
  final List<String> allSeasons;

  const _SeasonsBootstrap({
    required this.provider,
    required this.config,
    required this.allSeasons,
  });
}

class _SeasonTabs extends StatelessWidget {
  final int selectedIndex;
  final bool isArabic;
  final ValueChanged<int> onSelected;

  const _SeasonTabs({
    required this.selectedIndex,
    required this.isArabic,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final labels = isArabic
        ? const <String>['السابق', 'الحالي', 'القادم', 'المواسم الأخرى']
        : const <String>['Previous', 'Current', 'Next', 'Other seasons'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            _SeasonTabButton(
              label: labels[i],
              selected: selectedIndex == i,
              onTap: () => onSelected(i),
            ),
            if (i != labels.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _SeasonTabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SeasonTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.primary : colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.onPrimary : colors.onSurface,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _OtherSeasonsList extends StatelessWidget {
  final AnimeWitcherNativeProvider provider;
  final List<String> allSeasons;
  final bool isArabic;

  const _OtherSeasonsList({
    super.key,
    required this.provider,
    required this.allSeasons,
    required this.isArabic,
  });

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
      return Center(
        child: Text(
          isArabic ? 'لا توجد مواسم أخرى' : 'No other seasons available',
        ),
      );
    }

    const seasons = <String>['شتاء', 'ربيع', 'صيف', 'خريف'];
    final englishSeason = <String, String>{
      'شتاء': 'Winter',
      'ربيع': 'Spring',
      'صيف': 'Summer',
      'خريف': 'Fall',
    };

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
              Text(
                '$year',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (var i = 0; i < seasons.length; i++) ...[
                    Expanded(
                      child: _SeasonYearButton(
                        label: isArabic
                            ? seasons[i]
                            : englishSeason[seasons[i]]!,
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
        disabledForegroundColor: colors.onSurfaceVariant.withValues(alpha: 0.35),
        shape: const StadiumBorder(),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label, maxLines: 1),
      ),
    );
  }
}

class _SeasonResultsScreen extends StatelessWidget {
  final AnimeWitcherNativeProvider provider;
  final String season;

  const _SeasonResultsScreen({
    required this.provider,
    required this.season,
  });

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
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
                  child: Text(season),
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
      body: _SeasonGrid(
        provider: provider,
        season: season,
        emptyLabel: isArabic
            ? 'لا توجد أعمال في هذا الموسم'
            : 'No titles in this season',
      ),
    );
  }
}

class _SeasonGrid extends StatefulWidget {
  final AnimeWitcherNativeProvider provider;
  final String season;
  final String emptyLabel;

  const _SeasonGrid({
    super.key,
    required this.provider,
    required this.season,
    required this.emptyLabel,
  });

  @override
  State<_SeasonGrid> createState() => _SeasonGridState();
}

class _SeasonGridState extends State<_SeasonGrid>
    with AutomaticKeepAliveClientMixin<_SeasonGrid> {
  @override
  bool get wantKeepAlive => true;

  final ScrollController _controller = ScrollController();
  final List<MultimediaItem> _items = <MultimediaItem>[];
  final Set<String> _seen = <String>{};
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _loadNext();
  }

  @override
  void didUpdateWidget(covariant _SeasonGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.season != widget.season ||
        oldWidget.provider != widget.provider) {
      _items.clear();
      _seen.clear();
      _offset = 0;
      _hasMore = true;
      _error = null;
      _loading = false;
      _loadNext();
    }
  }

  void _onScroll() {
    if (!_controller.hasClients || _loading || !_hasMore) return;
    if (_controller.position.pixels >=
        _controller.position.maxScrollExtent - 500) {
      _loadNext();
    }
  }

  Future<void> _loadNext() async {
    if (_loading || !_hasMore || widget.season.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.provider.getSeasonPage(
        widget.season,
        offset: _offset,
        limit: 30,
      );
      if (!mounted) return;
      setState(() {
        for (final item in page.items) {
          final key = item.url.trim().isEmpty ? '${item.id}|${item.title}' : item.url;
          if (_seen.add(key)) _items.add(item);
        }
        _offset = page.nextOffset;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
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
    super.build(context);
    if (_items.isEmpty && _loading) {
      return const AnimeCatalogShimmer();
    }
    if (_items.isEmpty && _error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 120),
        children: [
          _LoadError(message: widget.emptyLabel, onRetry: _loadNext),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 120),
        children: [Center(child: Text(widget.emptyLabel))],
      );
    }

    final isDesktop = context.isDesktop;
    final extra = _loading || (_error != null && _hasMore) ? 1 : 0;
    return GridView.builder(
      controller: _controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 110),
      gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
        context,
        maxCrossAxisExtent: isDesktop ? 240 : 150,
        childAspectRatio: isDesktop ? 0.58 : 0.55,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _items.length + extra,
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          if (_error != null) {
            return IconButton(
              tooltip: 'Retry',
              onPressed: _loadNext,
              icon: const Icon(Icons.refresh_rounded),
            );
          }
          return const AnimePosterShimmer();
        }
        final item = _items[index];
        return MultimediaCard(
          key: ValueKey('season-${widget.season}-${item.url}'),
          imageUrl: item.posterImageUrl,
          title: item.title,
          heroTag: 'season-${widget.season}-${item.id}-$index',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DetailsScreen(item: item),
            ),
          ),
        );
      },
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
