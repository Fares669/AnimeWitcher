import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';

import 'home_provider.dart';
import 'home_section_titles.dart';
import 'home_state.dart';

import 'package:animewitcher/features/home/presentation/widgets/continue_watching_section.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';

import 'widgets/home_hero_carousel.dart';
import 'widgets/home_hero_layout.dart';
import 'widgets/media_horizontal_list.dart';
import 'view_all_screen.dart';
import '../../../shared/widgets/loading_indicator.dart';

import '../../../l10n/generated/app_localizations.dart';

import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
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
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';

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

class _HomeScreenState extends ConsumerState<HomeScreen>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _showBottomFade = ValueNotifier(false);

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

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
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _showBottomFade.dispose();
    super.dispose();
  }

  void _openNewsArticle(NewsItem item) {
    openNewsUrl(item);
  }

  Future<void> _openLinkedNewsAnime(
    BuildContext context,
    AnimeWitcherProvider provider,
    NewsItem item,
  ) async {
    final animeId = item.animeId?.trim();
    if (animeId == null || animeId.isEmpty) return;

    try {
      final baseUrl = provider.mainUrl.replaceFirst(RegExp(r'/$'), '');
      final details = await provider.getDetails(
        baseUrl + '/watch/' + Uri.encodeComponent(animeId),
      );
      if (!context.mounted) return;
      DetailsRoute(
        $extra: DetailsRouteExtra(item: details),
      ).push<void>(context);
    } catch (_) {
      // The article remains usable even if its linked anime is unavailable.
    }
  }

  void _openNewsList(
    BuildContext context,
    AnimeWitcherProvider provider,
    List<NewsItem> items,
  ) {
    pushOverTaskbar<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => NewsListScreen(
          initialItems: items,
          loadPage: (offset, limit) =>
              provider.getNewsPage(offset: offset, limit: limit),
          onOpen: (item) => _openNewsArticle(item),
          onAnimeTap: (item) {
            _openLinkedNewsAnime(context, provider, item);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final homeDataAsync = ref.watch(homeDataProvider);
    final continueWatching = ref.watch(continueWatchingProvider);
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isWidescreen = profile?.isTv == true ||
        context.isTv ||
        profile?.isLargeScreen == true ||
        context.isTabletOrLarger;

    final scaffold = AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _buildBody(
          context,
          homeDataAsync,
          continueWatching,
          isWidescreen: isWidescreen,
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
    AnimeWitcherProvider provider,
  ) {
    final entries = visibleHomeRailEntries(data).toList(growable: false);
    var newsAfterIndex = entries.indexWhere(
      (entry) => isMostWatchedAnimationSectionTitle(entry.key),
    );
    if (newsAfterIndex < 0) {
      newsAfterIndex = entries.indexWhere(
        (entry) => isLatestAddedSectionTitle(entry.key),
      );
    }
    if (newsAfterIndex < 0 && entries.isNotEmpty) {
      newsAfterIndex = entries.length - 1;
    }

    Widget buildNewsSection() {
      return NewsSection(
        title: Localizations.localeOf(context).languageCode == 'ar'
            ? 'الأخبار'
            : 'News',
        items: news,
        onViewAll: () => _openNewsList(context, provider, news),
        onOpen: _openNewsArticle,
        onAnimeTap: (item) {
          _openLinkedNewsAnime(context, provider, item);
        },
      );
    }

    final sections = <Widget>[];
    if (entries.isEmpty && news.isNotEmpty) {
      sections.add(buildNewsSection());
    }

    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      sections.add(
        MediaHorizontalList(
          title: entry.key,
          mediaList: entry.value,
          category: ViewAllCategory.providerContent,
          showViewAll: true,
          loadViewAllPage: (offset) => provider.getHomeSectionPage(
            entry.key,
            offset: offset,
            limit: provider.viewAllPageSize,
          ),
          onTap: (item) {
            DetailsRoute(
              $extra: DetailsRouteExtra(item: item),
            ).push<void>(context);
          },
          heroTagPrefix: 'home',
          forcePortrait: isLatestAddedSectionTitle(entry.key),
        ),
      );
      if (news.isNotEmpty && index == newsAfterIndex) {
        sections.add(buildNewsSection());
      }
    }

    return sections;
  }

  Widget _buildBody(
    BuildContext context,
    HomeState state,
    List<HistoryItem> continueWatching, {
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
      HomeSuccess(:final data, :final news) => _withGradientEdgeHint(
        MouseDragRefreshIndicator(
          onRefresh: () async {
            await Future.wait<void>([
              ref.read(continueWatchingProvider.notifier).refreshFromServer(),
              ref.read(homeDataProvider.notifier).fetch(keepCurrent: true),
            ]);
          },
          child: CustomScrollView(
            controller: _scrollController,
            slivers: [
              if (homeHeroMovies(data) != null)
                SliverToBoxAdapter(
                  child: HomeHeroCarousel(
                    movies: homeHeroMovies(data)!,
                    scrollController: _scrollController,
                    onTap: (item) {
                      DetailsRoute(
                        $extra: DetailsRouteExtra(item: item),
                      ).push<void>(context);
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

              if (continueWatching.isNotEmpty)
                SliverToBoxAdapter(
                  child: ContinueWatchingSection(
                    title: l10n.continueWatching,
                    items: continueWatching,
                    topPadding: isWidescreen ? 0 : null,
                  ),
                ),

              SliverList(
                delegate: SliverChildListDelegate(
                  _buildProviderSectionsWithNews(
                    context,
                    data,
                    news,
                    activeProvider,
                  ),
                ),
              ),

              const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
            ],
          ),
        ),
      ),
    };
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
