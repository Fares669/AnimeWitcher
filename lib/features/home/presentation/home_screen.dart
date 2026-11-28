import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/app_side_menu.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/core/navigation/home_tab_reselection.dart';

import '../../settings/presentation/general_settings_provider.dart';

import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/core/navigation/app_layout_style.dart';

import 'home_provider.dart';
import 'home_section_titles.dart';
import 'home_state.dart';
import 'latest_episodes_provider.dart';
import '../../news/presentation/open_news.dart';

import 'package:animewitcher/features/home/presentation/widgets/continue_watching_section.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';

import 'widgets/home_hero_carousel.dart';
import 'widgets/home_hero_layout.dart';
import 'widgets/latest_manga_chapters_section.dart';
import 'widgets/media_horizontal_list.dart';
import 'view_all_screen.dart';
import '../../../shared/widgets/loading_indicator.dart';

import '../../../l10n/generated/app_localizations.dart';

import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/home_section_titles.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';

import '../../../shared/widgets/shimmer_placeholder.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import '../../../shared/widgets/recoverable_network_state.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../core/providers/device_info_provider.dart';
import 'widgets/news_section.dart';
import '../../../shared/widgets/taskbar_visibility.dart';

import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:animewitcher/features/news/presentation/news_utils.dart';
import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/manga/presentation/manga_home_prefetch.dart';
import 'package:animewitcher/core/utils/localized_text.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

/// Hides the platform scrollbar — replaced by a gradient edge hint.
class _NoScrollbarBehavior extends ScrollBehavior {
  const _NoScrollbarBehavior();

  @override
  ScrollViewKeyboardDismissBehavior getKeyboardDismissBehavior(
    BuildContext context,
  ) => ScrollViewKeyboardDismissBehavior.onDrag;

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

// Section rules depend on ordered titles, not on the cards or late News
// and manga payloads. Keep only title metadata; read row items from the
// current catalogue even when a provider reuses the same keys.
class _HomeCatalogueLayout {
  _HomeCatalogueLayout(Iterable<String> keys) : keys = keys.toList() {
    for (final title in this.keys) {
      if (isHiddenHomeRailTitle(title)) continue;
      final index = rails.length;
      final isLatestAdded = isLatestAddedSectionTitle(title);
      if (latestEpisodesIndex < 0 && isLatestEpisodesSectionTitle(title)) {
        latestEpisodesIndex = index;
      }
      if (mostWatchedIndex < 0 && isMostWatchedAnimationSectionTitle(title)) {
        mostWatchedIndex = index;
      }
      if (latestAddedIndex < 0 && isLatestAdded) latestAddedIndex = index;
      rails.add((title, isLatestAdded));
    }
  }

  final List<String> keys;
  final rails = <(String, bool)>[];
  int latestEpisodesIndex = -1;
  int mostWatchedIndex = -1;
  int latestAddedIndex = -1;

  int get newsAfterIndex => mostWatchedIndex >= 0
      ? mostWatchedIndex
      : latestAddedIndex >= 0
      ? latestAddedIndex
      : rails.length - 1;

  bool matches(Map<String, List<MultimediaItem>> data) {
    if (data.length != keys.length) return false;
    var index = 0;
    for (final title in data.keys) {
      if (title != keys[index++]) return false;
    }
    return true;
  }
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  static const _rankingRails = <(MalRanking, String, String)>[
    (MalRanking.airing, 'Trending now', 'رائج الآن'),
    (MalRanking.top, 'Top rated', 'الأفضل'),
    (MalRanking.popular, 'Most watched', 'الأكثر مشاهدة'),
  ];

  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _showBottomFade = ValueNotifier(false);
  final _refreshIndicatorKey = GlobalKey<RefreshIndicatorState>();
  Future<void>? _refreshFuture;
  Future<void>? _homeReselectionFuture;
  Future<void>? _refreshIndicatorDismissal;
  late final AnimationController _refreshDismissalController;
  _HomeCatalogueLayout? _catalogueLayout;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _refreshDismissalController = AnimationController(
      vsync: this,
      duration: kThemeAnimationDuration,
    );
    _scrollController.addListener(_onScroll);
    // Preload only the rankings Home can display, directly in the provider
    // each rail watches. Hidden rankings don't need to run at startup.
    for (final (ranking, _, _) in _rankingRails) {
      ref.read(homeMalRankingPageProvider(ranking).future).ignore();
    }
    // Once home has had the network to itself for a while, the manga tab's
    // first page is fetched too, so the tab opens already filled.
    _prefetchTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted || !ref.read(mangaHasOwnTabProvider)) return;
      ref
          .read(mangaHomeWarmupProvider)
          .prefetch(() => mangaCatalogueOf(ref.read(extensionManagerProvider)));
    });
  }

  Timer? _prefetchTimer;

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    // Track gradient edge hint visibility — fades away near the bottom.
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    final showFade = maxScroll > 0 && currentScroll < maxScroll - 10;
    if (showFade != _showBottomFade.value) {
      _showBottomFade.value = showFade;
    }
  }

  @override
  void dispose() {
    _prefetchTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _refreshDismissalController.dispose();
    _showBottomFade.dispose();
    super.dispose();
  }

  Future<void> _refresh() {
    if (_refreshFuture != null) return _refreshFuture!;
    ref.invalidate(secondaryLatestEpisodesProvider);
    for (final (ranking, _, _) in _rankingRails) {
      ref.invalidate(homeMalRankingPageProvider(ranking));
    }
    return _refreshFuture =
        Future.wait<void>([
              ref.read(continueWatchingProvider.notifier).refreshFromServer(),
              ref.read(homeDataProvider.notifier).fetch(keepCurrent: true),
            ])
            .then<void>((_) {})
            .catchError((Object _) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    appText(
                      context,
                      english: 'Unable to refresh. Try again.',
                      arabic: 'تعذر تحديث الصفحة. حاول مرة أخرى.',
                    ),
                  ),
                ),
              );
            })
            .whenComplete(() {
              _refreshFuture = null;
              if (!mounted) return;
              // Material's show future completes before its scale-out animation.
              _refreshIndicatorDismissal = _refreshDismissalController
                  .forward(from: 0)
                  .orCancel
                  .then<void>((_) async {
                    if (mounted) await WidgetsBinding.instance.endOfFrame;
                  })
                  .catchError((Object _) {});
            });
  }

  void _onHomeTabReselected() {
    (_homeReselectionFuture ??= _scrollToTopAndRefresh().whenComplete(
      () => _homeReselectionFuture = null,
    )).ignore();
  }

  Future<void> _scrollToTopAndRefresh() async {
    if (_scrollController.hasClients) {
      final top = _scrollController.position.minScrollExtent;
      if (MediaQuery.disableAnimationsOf(context)) {
        _scrollController.jumpTo(top);
      } else if (_scrollController.offset != top) {
        await _scrollController.animateTo(
          top,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    }
    final dismissal = _refreshIndicatorDismissal;
    if (dismissal != null) await dismissal;
    if (!mounted) return;
    final indicator = _refreshIndicatorKey.currentState;
    if (indicator != null) {
      indicator.show().ignore();
    } else {
      await _refresh();
    }
  }

  void _openNewsArticle(NewsItem item) {
    openNewsUrl(item);
  }

  void _openNewsList(
    BuildContext context,
    AnimeWitcherProvider provider,
    List<NewsItem> items,
  ) {
    pushOverTaskbar<void>(
      context,
      MaterialPageRoute<void>(
        builder: (routeContext) => NewsListScreen(
          initialItems: items,
          loadPage: (offset, limit) =>
              provider.getNewsPage(offset: offset, limit: limit),
          onOpen: (item) => _openNewsArticle(item),
          onAnimeTap: (item) {
            openLinkedNewsAnime(routeContext, provider, item);
          },
        ),
      ),
    );
  }

  HomeState _watchHomeWithoutNews() {
    ref.watch(
      homeDataProvider.select(
        (state) => switch (state) {
          HomeSuccess(:final data, :final latestManga) => (data, latestManga),
          _ => state,
        },
      ),
    );
    return ref.read(homeDataProvider);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(homeTabReselectionProvider, (_, _) => _onHomeTabReselected());
    // On a desktop or tablet the shell has its own News button, which reads
    // the latest articles on tap. Only phones render the News rail here.
    final showNewsOnHome = !appLayoutsAvailable(context);
    final homeDataAsync = showNewsOnHome
        ? ref.watch(homeDataProvider)
        : _watchHomeWithoutNews();
    // Keep history subscribed from startup, but only rearrange Home when
    // the shelf appears or disappears. Progress updates belong to its cards.
    final hasContinueWatching = ref.watch(
      continueWatchingProvider.select((items) => items.isNotEmpty),
    );
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isWidescreen =
        profile?.isTv == true ||
        context.isTv ||
        profile?.isLargeScreen == true ||
        context.isTabletOrLarger;

    final scaffold = AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        // The theme's page colour, so the amber theme reaches home too.
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Stack(
          children: [
            Positioned.fill(
              child: _buildBody(
                context,
                homeDataAsync,
                hasContinueWatching: hasContinueWatching,
                showNewsOnHome: showNewsOnHome,
                isWidescreen: isWidescreen,
              ),
            ),
            // The side menu's button, over the artwork in the corner the
            // menu comes from; nothing in the other layouts.
            Positioned(
              top: MediaQuery.viewPaddingOf(context).top + 8,
              left: 12,
              child: const AppSideMenuButton(overArtwork: true),
            ),
          ],
        ),
      ),
    );

    if (!appleUsesPersistentLiquidGlassHeader) return scaffold;
    return ApplePersistentGlassHeaderScope(
      branchIndex: TaskbarDestination.home.branchIndex,
      trailingButtons: const <AppleLiquidGlassToolbarButton>[],
      child: scaffold,
    );
  }

  List<Widget> _buildProviderSectionsWithNews(
    BuildContext context,
    Map<String, List<MultimediaItem>> data,
    List<NewsItem> news,
    List<MangaLatestChapter> latestManga,
    AnimeWitcherProvider provider,
    List<Widget> secondaryEpisodeRails,
    _HomeCatalogueLayout layout,
  ) {
    final entries = layout.rails;
    final latestEpisodesIndex = layout.latestEpisodesIndex;
    final newsAfterIndex = layout.newsAfterIndex;
    final mangaHasOwnTab = ref.watch(mangaHasOwnTabProvider);

    Widget buildNewsSection() {
      return NewsSection(
        title: 'الأخبار',
        items: news,
        onViewAll: () => _openNewsList(context, provider, news),
        onOpen: _openNewsArticle,
        onAnimeTap: (item) {
          openLinkedNewsAnime(context, provider, item);
        },
      );
    }

    final sections = <Widget>[];
    if (latestEpisodesIndex < 0) sections.addAll(secondaryEpisodeRails);
    if (entries.isEmpty && news.isNotEmpty) {
      sections.add(buildNewsSection());
    }

    for (var index = 0; index < entries.length; index++) {
      final (title, forcePortrait) = entries[index];
      sections.add(
        _buildMediaSection(
          context,
          provider,
          title,
          data[title]!,
          forcePortrait: forcePortrait,
        ),
      );
      if (index == latestEpisodesIndex) sections.addAll(secondaryEpisodeRails);
      // With manga on a tab of its own, its new chapters live there.
      if (latestManga.isNotEmpty &&
          !mangaHasOwnTab &&
          index == latestEpisodesIndex) {
        sections.add(
          LatestMangaChaptersSection(
            title: AppLocalizations.of(context)!.latestChapters,
            items: latestManga,
            onTap: (latest) {
              MangaDetailsRoute(
                $extra: MangaDetailsRouteExtra(item: latest.manga),
              ).push<void>(context);
            },
          ),
        );
      }
      if (news.isNotEmpty && index == newsAfterIndex) {
        sections.add(buildNewsSection());
      }
      // MyAnimeList's rankings, after the newest episodes.
      if (index == 0) sections.addAll(_malRankingRails(context));
    }
    if (entries.isEmpty) sections.addAll(_malRankingRails(context));

    return sections;
  }

  Widget _buildMediaSection(
    BuildContext context,
    AnimeWitcherProvider provider,
    String sectionTitle,
    List<MultimediaItem> mediaList, {
    String? title,
    required bool forcePortrait,
  }) {
    return MediaHorizontalList(
      key: ValueKey((provider.packageName, sectionTitle)),
      title: title ?? sectionTitle,
      mediaList: mediaList,
      warmProviderPosters: true,
      category: ViewAllCategory.providerContent,
      loadViewAllPage: (offset) => provider.getHomeSectionPage(
        sectionTitle,
        offset: offset,
        limit: provider.viewAllPageSize,
      ),
      onTap: (item) => item.openDetails(context),
      heroTagPrefix: title == null ? 'home' : 'home_${provider.packageName}',
      forcePortrait: forcePortrait,
    );
  }

  /// MyAnimeList's rankings — popular now, best rated, most watched — as
  /// rails with their "view all" pages. Only the catalogue's own shows are
  /// in them; a ranking not fetched yet is left out until it is.
  List<Widget> _malRankingRails(BuildContext context) {
    if (ref.watch(activeProviderProvider) is! AnimeWitcherNativeProvider) {
      return const <Widget>[];
    }
    final load = ref.watch(malRankingLoaderProvider);
    final rails = <Widget>[];
    for (final (ranking, english, arabic) in _rankingRails) {
      final page = ref.watch(homeMalRankingPageProvider(ranking)).value;
      if (page == null || (page.items.isEmpty && !page.hasMore)) continue;
      final items = page.items;
      rails.add(
        MediaHorizontalList(
          key: ValueKey<String>('home-mal-${ranking.name}'),
          title: appText(context, english: english, arabic: arabic),
          mediaList: items.take(malRankingPageSize).toList(growable: false),
          // Keep ranking data ready, but leave encoded poster warming to the
          // mounted rail's post-frame path, behind the visible cards.
          warmProviderPosters: true,
          category: ViewAllCategory.providerContent,
          showViewAll: true,
          loadViewAllPage: (offset) => load(ranking, offset),
          initialViewAllOffset: page.nextOffset,
          initialViewAllHasMore: page.hasMore,
          showWhenEmpty: page.hasMore,
          onTap: (item) {
            item.openDetails(context);
          },
          heroTagPrefix: 'home_mal_${ranking.name}',
          forcePortrait: true,
        ),
      );
    }
    return rails;
  }

  Widget _buildBody(
    BuildContext context,
    HomeState state, {
    required bool hasContinueWatching,
    required bool showNewsOnHome,
    bool isWidescreen = false,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final isResolving = ref.watch(providerResolutionLoadingProvider);

    if (isResolving) {
      return Center(
        child: AppLoadingIndicator(
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    }

    final activeProvider = ref.watch(activeProviderProvider);
    if (activeProvider == null) {
      return _buildNoProviderState(context, l10n, isWidescreen: isWidescreen);
    }
    final secondarySources = ref
        .watch(extensionManagerProvider)
        .where(
          (source) =>
              source.packageName != activeProvider.packageName &&
              source.supportedTypes.contains(ProviderType.anime),
        );
    final secondaryEpisodeRails = <Widget>[
      for (final source in secondarySources)
        if (ref
            .watch(latestEpisodesSettingsProvider)
            .contains(source.packageName))
          if (ref.watch(secondaryLatestEpisodesProvider(source)).value
              case final entry? when entry.value.isNotEmpty)
            _buildMediaSection(
              context,
              source,
              entry.key,
              entry.value,
              title: 'أحدث الحلقات (${source.name})',
              forcePortrait: isLatestAddedSectionTitle(entry.key),
            ),
    ];

    return switch (state) {
      HomeLoading() => _withGradientEdgeHint(
        CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverToBoxAdapter(child: _buildCarouselShimmer(context)),
            SliverToBoxAdapter(child: _buildListShimmer(context)),
            SliverToBoxAdapter(child: _buildListShimmer(context)),
            SliverToBoxAdapter(child: _buildListShimmer(context)),
          ],
        ),
      ),
      HomeNoProvider() => _buildNoProviderState(
        context,
        l10n,
        isWidescreen: isWidescreen,
      ),
      HomeOffline() => _buildErrorState(context, ref),
      HomeError() => _buildErrorState(context, ref),
      HomeSuccess() => _buildSuccessBody(
        context,
        l10n,
        state,
        activeProvider,
        secondaryEpisodeRails,
        hasContinueWatching: hasContinueWatching,
        showNewsOnHome: showNewsOnHome,
        isWidescreen: isWidescreen,
      ),
    };
  }

  Widget _buildSuccessBody(
    BuildContext context,
    AppLocalizations l10n,
    HomeSuccess state,
    AnimeWitcherProvider activeProvider,
    List<Widget> secondaryEpisodeRails, {
    required bool hasContinueWatching,
    required bool showNewsOnHome,
    required bool isWidescreen,
  }) {
    final HomeSuccess(:data, news: homeNews, :latestManga) = state;
    var layout = _catalogueLayout;
    if (layout == null || !layout.matches(data)) {
      _catalogueLayout = layout = _HomeCatalogueLayout(data.keys);
    }
    final heroMovies =
        data['Trending'] ??
        (layout.rails.isEmpty ? null : data[layout.rails.first.$1]);
    return _withGradientEdgeHint(
      MouseDragRefreshIndicator(
        indicatorKey: _refreshIndicatorKey,
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
            if (heroMovies != null)
              SliverToBoxAdapter(
                child: HomeHeroCarousel(
                  movies: heroMovies,
                  scrollController: _scrollController,
                  onTap: (item) {
                    item.openDetails(context);
                  },
                ),
              )
            else if (!isWidescreen)
              // Keep content below the status area when no banner is present.
              SliverPadding(
                padding: EdgeInsets.only(
                  top: MediaQuery.viewPaddingOf(context).top,
                ),
              ),

            if (hasContinueWatching)
              SliverToBoxAdapter(
                child: Consumer(
                  builder: (context, ref, _) => ContinueWatchingSection(
                    title: l10n.continueWatching,
                    items: ref.watch(continueWatchingProvider),
                    topPadding: isWidescreen ? 0 : null,
                  ),
                ),
              ),

            SliverList(
              delegate: SliverChildListDelegate(
                _buildProviderSectionsWithNews(
                  context,
                  data,
                  showNewsOnHome ? homeNews : const <NewsItem>[],
                  latestManga,
                  activeProvider,
                  secondaryEpisodeRails,
                  layout,
                ),
              ),
            ),

            const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
          ],
        ),
      ),
    );
  }

  Widget _withGradientEdgeHint(Widget scrollView) {
    return Stack(
      children: [
        ScrollConfiguration(
          behavior: const _NoScrollbarBehavior(),
          child: scrollView,
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 48, // Taller height for smoother blend
          child: ValueListenableBuilder<bool>(
            valueListenable: _showBottomFade,
            builder: (context, show, _) {
              if (!show) return const SizedBox.shrink();
              final surfaceColor = Theme.of(context).colorScheme.surface;
              return IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        surfaceColor.withValues(alpha: 0.0),
                        surfaceColor.withValues(alpha: 0.15),
                        surfaceColor.withValues(alpha: 0.45),
                        surfaceColor.withValues(alpha: 0.8),
                        surfaceColor,
                      ],
                      stops: const [0.0, 0.5, 0.75, 0.9, 1.0],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildNoProviderState(
    BuildContext context,
    AppLocalizations l10n, {
    bool isWidescreen = false,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.extension_off_rounded,
            size: 64,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.selectProviderToStart,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (isWidescreen) ...[
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => ref.invalidate(homeDataProvider),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(l10n.retry),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    LayoutConstants.radiusPill,
                  ),
                ),
              ),
            ),
          ] else
            Text(l10n.tapExtensionIcon),
        ],
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, WidgetRef ref) {
    return RecoverableNetworkState(
      onRetry: () => ref.read(homeDataProvider.notifier).retry(),
      onOpenDownloads: () => const DownloadsRoute().go(context),
    );
  }

  Widget _buildCarouselShimmer(BuildContext context) {
    return HomeHeroFrame(
      builder: (context, heroHeight) => ShimmerPlaceholder.rectangular(
        width: double.infinity,
        height: heroHeight,
        borderRadius: 0,
      ),
    );
  }

  Widget _buildListShimmer(BuildContext context) {
    final isDesktop = context.isDesktop;
    final isHandsetLandscape = context.isHandsetLandscape;
    final spacing = isDesktop
        ? LayoutConstants.spacingLg
        : isHandsetLandscape
        ? ResponsiveBreakpoints.handsetLandscapeGridMaxSpacing
        : LayoutConstants.spacingSm;
    // Must match MediaHorizontalList exactly, otherwise the rail visibly
    // resizes when the shimmer is replaced by the real cards.
    final cardWidth = MultimediaCardLayout.cardWidth(
      context,
      isPortrait: true,
      horizontalPadding: isDesktop
          ? LayoutConstants.dashboardContentPadding
          : LayoutConstants.spacingMd,
      spacing: spacing,
    );
    final listHeight = MultimediaCardLayout.listHeight(
      cardWidth,
      isPortrait: true,
      isDesktop: isDesktop,
    );

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              isDesktop
                  ? LayoutConstants.dashboardContentPadding
                  : LayoutConstants.spacingMd,
              LayoutConstants.spacingLg,
              isDesktop
                  ? LayoutConstants.dashboardContentPadding
                  : LayoutConstants.spacingMd,
              LayoutConstants.spacingSm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: ShimmerPlaceholder.rectangular(
                      width: 150,
                      height: 24,
                      borderRadius: 4,
                    ),
                  ),
                ),
                const SizedBox(width: LayoutConstants.spacingMd),
                ShimmerPlaceholder.rectangular(
                  width: 84,
                  height: 30,
                  borderRadius: 20,
                ),
              ],
            ),
          ),
          const SizedBox(height: LayoutConstants.spacingMd),
          SizedBox(
            height: listHeight,
            child: ListView.separated(
              padding: EdgeInsets.symmetric(
                horizontal: isDesktop
                    ? LayoutConstants.dashboardContentPadding
                    : LayoutConstants.spacingMd,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: 10,
              separatorBuilder: (_, _) => SizedBox(width: spacing),
              itemBuilder: (context, index) {
                return SizedBox(
                  width: cardWidth,
                  height: listHeight,
                  child: const AnimePosterShimmer(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
