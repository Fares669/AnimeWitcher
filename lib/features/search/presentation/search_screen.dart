import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:animewitcher/features/home/presentation/widgets/home_section_header.dart';
import 'package:animewitcher/shared/widgets/app_side_menu.dart';
import 'package:animewitcher/shared/widgets/app_search_field.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';

import '../../../core/account/animewitcher_character_models.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/providers/device_info_provider.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../home/presentation/widgets/provider_search_filter_dialog.dart';
import '../../characters/presentation/character_card.dart';
import '../../characters/presentation/character_details_screen.dart';
import 'search_domain.dart';
import 'search_provider.dart';
import 'search_text_direction.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'widgets/search_action_buttons.dart';
import 'widgets/search_glass_surface.dart';
import 'widgets/search_result_section.dart';
import 'widgets/search_header_bar.dart';
import 'widgets/search_sort_dialog.dart';
import '../../../shared/widgets/catalog_direction.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/app_page_header.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import '../../../shared/widgets/recoverable_network_state.dart';
import '../../../shared/widgets/glass_dialog.dart';

import 'package:animewitcher/core/utils/localized_text.dart';

import '../data/recent_searches.dart';
import 'widgets/recent_searches_view.dart';
import 'widgets/search_start_page.dart';
import '../../library/presentation/history_provider.dart';
import '../../../core/account/account_providers.dart';
import '../../../core/storage/library_category.dart';
import '../../../core/storage/history_repository.dart';
import '../../../core/storage/library_repository.dart';
import 'widgets/search_instant_results.dart';
import 'widgets/phone_suggestion_box.dart';
import '../../home/presentation/home_provider.dart';
import '../../home/presentation/home_state.dart';
import '../data/mal_rankings.dart';
import '../../home/presentation/view_all_screen.dart';
import '../../../core/domain/entity/multimedia_item.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final FocusNode _clearButtonFocusNode = FocusNode();
  final FocusNode _firstSuggestionFocusNode = FocusNode();
  final FocusNode _firstResultFocusNode = FocusNode();
  final ScrollController _resultsScrollController = ScrollController();
  ProviderSubscription<int>? _clearRequestSub;
  ProviderSubscription<int>? _focusRequestSub;
  bool _isLoadingProviderFilters = false;

  @override
  void initState() {
    super.initState();
    // Restore any previously committed query into the text field.
    _controller.text = ref.read(searchQueryProvider);
    _clearRequestSub = ref.listenManual<int>(searchClearRequestProvider, (
      previous,
      next,
    ) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.clear();
      });
    });
    _focusRequestSub = ref.listenManual<int>(searchFocusRequestProvider, (
      previous,
      next,
    ) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _requestSearchFocus();
        final textLength = _controller.text.length;
        _controller.selection = TextSelection.collapsed(offset: textLength);
      });
    });
    _controller.addListener(_onTextChanged);
    _resultsScrollController.addListener(_onResultsScroll);
    // The filter provider outlives this screen, so reopening search resets it
    // to the content tab. Deferred by a frame because initState runs while
    // the tree is building, and Riverpod rejects writes during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(searchFilterProvider.notifier).set(SearchFilter.content);
    });

    _focusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent) {
        // Esc closes the results panel, as in Harbor.
        if (event.logicalKey == LogicalKeyboardKey.escape &&
            _controller.text.isNotEmpty) {
          _closeResultsPanel();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (_controller.text.isNotEmpty &&
              _controller.selection.extentOffset == _controller.text.length) {
            _clearButtonFocusNode.requestFocus();
            return KeyEventResult.handled;
          }
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          final suggestionState = ref.read(searchSuggestionControllerProvider);
          final hasSuggestions =
              suggestionState.query.trim().length >= 2 &&
              (suggestionState.isLoading ||
                  suggestionState.suggestions.isNotEmpty);
          if (hasSuggestions) {
            _firstSuggestionFocusNode.requestFocus();
          } else {
            _firstResultFocusNode.requestFocus();
          }
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    };

    _clearButtonFocusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent) {
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _requestSearchFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          final suggestionState = ref.read(searchSuggestionControllerProvider);
          final hasSuggestions =
              suggestionState.query.trim().length >= 2 &&
              (suggestionState.isLoading ||
                  suggestionState.suggestions.isNotEmpty);
          if (hasSuggestions) {
            _firstSuggestionFocusNode.requestFocus();
          } else {
            _firstResultFocusNode.requestFocus();
          }
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    };

    _firstResultFocusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _requestSearchFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _requestSearchFocus() {
    _focusNode.requestFocus();
  }

  void _onResultsScroll() {
    if (!_resultsScrollController.hasClients) return;
    if (_resultsScrollController.position.extentAfter < 600) {
      ref.read(searchPagedResultsProvider.notifier).loadMore();
    }
  }

  @override
  void dispose() {
    _clearRequestSub?.close();
    _focusRequestSub?.close();
    _controller.removeListener(_onTextChanged);
    _resultsScrollController.removeListener(_onResultsScroll);
    _resultsScrollController.dispose();
    _controller.dispose();
    _focusNode.dispose();
    _clearButtonFocusNode.dispose();
    _firstSuggestionFocusNode.dispose();
    _firstResultFocusNode.dispose();
    super.dispose();
  }

  Future<void> _showSearchFilters() async {
    if (_isLoadingProviderFilters) return;
    final providers = ref
        .read(extensionManagerProvider.notifier)
        .getAllProviders();
    if (providers.isEmpty) return;

    setState(() => _isLoadingProviderFilters = true);
    ProviderSearchFilters? selected;
    SearchDomain? pickedDomain;
    try {
      final provider = providers.first;
      // All, anime, animation, manga and characters are the sheet's main
      // categories; only the ones that can be filtered bring their tabs.
      Future<ProviderSearchFilterOptions> optionsFor(SearchDomain domain) {
        if (!domain.capabilities.showFilter) {
          return Future.value(const ProviderSearchFilterOptions());
        }
        return switch (domain) {
          SearchDomain.anime => provider.getSearchFilterOptions(),
          // The anime filters, less the tag every animation result has.
          SearchDomain.animation => provider.getSearchFilterOptions().then(
            (options) => ProviderSearchFilterOptions(
              statuses: options.statuses,
              types: options.types,
              ageRatings: options.ageRatings,
              years: options.years,
              seasons: options.seasons,
              genres: options.genres
                  .where((genre) => genre != 'انميشن')
                  .toList(growable: false),
            ),
          ),
          SearchDomain.manga => provider.getMangaSearchFilterOptions(),
          SearchDomain.all || SearchDomain.characters => Future.value(
            const ProviderSearchFilterOptions(),
          ),
        };
      }

      final domain = ref.read(searchDomainProvider);
      final options = await optionsFor(domain);
      if (!mounted) return;

      // Use the exact same filter surface as the Home page so both entry
      // points have identical tabs, spacing, selection behavior, and glass.
      // A phone's filters rise from the bottom over the whole screen.
      final sheet = _isPhone(context);
      Widget filters(BuildContext dialogContext) => ProviderSearchFilterDialog(
        asSheet: sheet,
        options: options,
        initialValue: ref.read(searchProviderFiltersProvider),
        categories: [
          for (final value in SearchDomain.values)
            ProviderSearchFilterCategory(
              value: value.name,
              label: searchDomainLabel(dialogContext, value),
              icon: searchDomainIcon(value),
              noFiltersNote: switch (value) {
                SearchDomain.all => appText(
                  dialogContext,
                  english: 'All searches every section at once. Pick anime, animation or manga to filter one of them.',
                  arabic: 'الكل يبحث في كل الأقسام معًا. اختر أنمي أو انميشن أو مانجا لتصفية قسم منها.',
                ),
                SearchDomain.characters => appText(
                  dialogContext,
                  english: 'Characters are found by name: type one in search.',
                  arabic: 'الشخصيات يُبحث عنها بالاسم: اكتب اسمًا في البحث.',
                ),
                _ => null,
              },
            ),
        ],
        category: domain.name,
        optionsFor: (name) => optionsFor(SearchDomain.values.byName(name)),
        onCategoryApplied: (name) =>
            pickedDomain = SearchDomain.values.byName(name),
      );
      selected = sheet
          ? await showProviderSearchFilterSheet(
              context: context,
              builder: filters,
            )
          : await showGlassDialog<ProviderSearchFilters>(
              context: context,
              builder: filters,
            );
    } finally {
      if (mounted) setState(() => _isLoadingProviderFilters = false);
    }

    if (!mounted || selected == null) return;
    if (pickedDomain != null) _selectSearchDomain(pickedDomain!);
    _resetResultsScrollPosition();
    ref.read(searchProviderFiltersProvider.notifier).set(selected);
    ref.read(searchFilterProvider.notifier).set(SearchFilter.content);
  }

  void _removeSearchFilter(String group, String value) {
    final current = ref.read(searchProviderFiltersProvider);
    final updated = switch (group) {
      'statuses' => current.copyWith(
        statuses: {...current.statuses}..remove(value),
      ),
      'types' => current.copyWith(types: {...current.types}..remove(value)),
      'ageRatings' => current.copyWith(
        ageRatings: {...current.ageRatings}..remove(value),
      ),
      'years' => current.copyWith(years: {...current.years}..remove(value)),
      'seasons' => current.copyWith(
        seasons: {...current.seasons}..remove(value),
      ),
      'genres' => current.copyWith(genres: {...current.genres}..remove(value)),
      _ => current,
    };

    if (identical(updated, current)) return;
    ref.read(searchProviderFiltersProvider.notifier).set(updated);
    ref.read(searchFilterProvider.notifier).set(SearchFilter.content);
  }

  void _applySearchSort(String selected) {
    final current = ref.read(searchProviderFiltersProvider);
    if (selected == current.sort) return;

    _resetResultsScrollPosition();
    ref
        .read(searchProviderFiltersProvider.notifier)
        .set(current.copyWith(sort: selected));
    ref.read(searchFilterProvider.notifier).set(SearchFilter.content);
  }

  List<AppleNativeMenuItem> _searchSortMenuItems(BuildContext context) {
    return <AppleNativeMenuItem>[
      for (final option in SearchSortOption.values)
        AppleNativeMenuItem(
          value: option.value,
          label: option.label(context),
          systemImage: _searchSortSystemImage(option),
          icon: _searchSortFallbackIcon(option),
        ),
    ];
  }

  String _searchSortSystemImage(SearchSortOption option) {
    return switch (option) {
      SearchSortOption.mostFavorited => 'star.fill',
      SearchSortOption.productionDateAscending => 'arrow.up',
      SearchSortOption.productionDateDescending => 'arrow.down',
      SearchSortOption.nameAscending => 'animewitcher.abc',
      SearchSortOption.nameDescending => 'animewitcher.zyx',
    };
  }

  IconData _searchSortFallbackIcon(SearchSortOption option) {
    return switch (option) {
      SearchSortOption.mostFavorited => Icons.star_rounded,
      SearchSortOption.productionDateAscending => Icons.arrow_upward_rounded,
      SearchSortOption.productionDateDescending => Icons.arrow_downward_rounded,
      SearchSortOption.nameAscending => Icons.abc_rounded,
      SearchSortOption.nameDescending => Icons.sort_by_alpha_rounded,
    };
  }

  void _selectSearchDomain(SearchDomain domain) {
    if (ref.read(searchDomainProvider) == domain) return;
    _resetResultsScrollPosition();
    ref.read(searchDomainProvider.notifier).set(domain);
  }

  void _resetResultsScrollPosition() {
    if (_resultsScrollController.hasClients) {
      _resultsScrollController.jumpTo(0);
    }
  }

  /// Closes the floating results: the typed text goes, the page returns.
  void _closeResultsPanel() {
    _controller.clear();
    ref.read(searchSuggestionControllerProvider.notifier).clear();
    ref.read(searchQueryProvider.notifier).set('');
    _focusNode.requestFocus();
  }

  /// From a search's results back to the search page, keyboard down.
  void _backToSearchPage() {
    _controller.clear();
    ref.read(searchSuggestionControllerProvider.notifier).clear();
    ref.read(searchQueryProvider.notifier).set('');
    _focusNode.unfocus();
  }

  void _submitSearch(String val) {
    final trimmed = val.trim();
    _resetResultsScrollPosition();
    _controller.value = TextEditingValue(
      text: trimmed,
      selection: TextSelection.collapsed(offset: trimmed.length),
    );
    ref.read(searchSuggestionControllerProvider.notifier).clear();
    ref.read(searchQueryProvider.notifier).set(trimmed);
    // Recorded on submit rather than as you type: a half-typed title is not
    // a search anyone wants offered back to them.
    ref.read(recentSearchesProvider.notifier).record(trimmed);
    // Keep the field focused after Search/Enter. The app-wide scroll behavior
    // dismisses the keyboard only when the user starts dragging a scroll view.
  }

  Future<void> _retrySearch() async {
    _resetResultsScrollPosition();
    await ref.read(searchPagedResultsProvider.notifier).retry();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv == true || context.isTv;
    final isWidescreen = isTv || context.isTabletOrLarger;

    final theme = Theme.of(context);
    final domain = ref.watch(searchDomainProvider);
    final domainCapabilities = domain.capabilities;

    if (isWidescreen) {
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Stack(
          children: [
            // The results run to the top of the window and scroll under the
            // controls, so the strip the controls sit on shows the artwork
            // moving behind them rather than a band of background colour.
            Positioned.fill(
              child: _buildBody(
                context,
                withFilterChips: true,
                topInset: _floatingHeaderExtent + 16,
              ),
            ),

            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SizedBox(
                height:
                    _floatingHeaderExtent +
                    MediaQuery.paddingOf(context).top,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const AppProgressiveHeaderBackdrop(),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: SearchHeaderBar(
                    textController: _controller,
                    searchFocusNode: _focusNode,
                    clearButtonFocusNode: _clearButtonFocusNode,
                    isCompact: false,
                    onRandom: _surpriseMe,
                    isRandomLoading: _surprising,
                    onShowFilters: _showSearchFilters,
                    onSortSelected: _applySearchSort,
                    sortValue: ref.watch(searchProviderFiltersProvider).sort,
                    sortItems: _searchSortMenuItems(context),
                    sortIcon: _searchSortFallbackIcon(
                      SearchSortOption.fromValue(
                        ref.watch(searchProviderFiltersProvider).sort,
                      ),
                    ),
                    sortSystemImage: _searchSortSystemImage(
                      SearchSortOption.fromValue(
                        ref.watch(searchProviderFiltersProvider).sort,
                      ),
                    ),
                    sortTooltip:
                        '${appText(context, english: 'Sort by', arabic: 'الترتيب حسب')}: '
                        '${SearchSortOption.fromValue(ref.watch(searchProviderFiltersProvider).sort).label(context)}',
                    activeFilterCount: domainCapabilities.showFilter
                        ? ref.watch(searchProviderFiltersProvider).count
                        : 0,
                    isFilterLoading: _isLoadingProviderFilters,
                    showSort: domainCapabilities.showSort,
                    // Always there: the filter sheet is also where the category is
                    // picked, anime or manga, so every category needs a way in.
                    showFilter: true,
                    onSubmitted: _submitSearch,
                        onChanged: (val) {
                          ref
                              .read(
                                searchSuggestionControllerProvider.notifier,
                              )
                              .onQueryChanged(val);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Mobile layout: existing AppBar
    return _buildMobileLayout(context);
  }

  Widget _buildMobileSearchActionGroup(BuildContext context) {
    final activeFilters = ref.watch(searchProviderFiltersProvider);
    final sortOption = SearchSortOption.fromValue(activeFilters.sort);
    final domain = ref.watch(searchDomainProvider);
    final capabilities = domain.capabilities;

    return SearchActionButtons(
      onRandom: _surpriseMe,
      isRandomLoading: _surprising,
      randomTooltip: appText(
        context,
        english: 'Surprise me',
        arabic: 'اقترح لي أنمي',
      ),
      showSort: capabilities.showSort,
      // The sheet also picks the category, so it is always there.
      showFilter: true,
      filterCount: capabilities.showFilter ? activeFilters.count : 0,
      isFilterLoading: _isLoadingProviderFilters,
      sortValue: activeFilters.sort,
      sortItems: _searchSortMenuItems(context),
      onSortSelected: _applySearchSort,
      sortIcon: _searchSortFallbackIcon(sortOption),
      sortSystemImage: _searchSortSystemImage(sortOption),
      sortTooltip:
          '${appText(context, english: 'Sort by', arabic: 'الترتيب حسب')}: ${sortOption.label(context)}',
      filterTooltip: appText(context, english: 'Filters', arabic: 'الفلاتر'),
      // Match the library filter's theme accent.
      tintColor: Theme.of(context).colorScheme.primary,
      height: SearchGlassSurface.height,
      onFilterPressed: _showSearchFilters,
    );
  }

  Widget _buildMobileSearchField(BuildContext context) {
    final theme = Theme.of(context);
    final fieldDirection = Directionality.of(context);
    final searchPlaceholder = searchDomainHint(
      context,
      ref.watch(searchDomainProvider),
    );
    // Only whether a search is running: watching the whole results state
    // rebuilt the field with every page of results that came in.
    final searching = ref.watch(
      searchPagedResultsProvider.select((state) => state.isLoading),
    );

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, child) {
        Widget? suffix;
        if (searching) {
          suffix = Padding(
            padding: const EdgeInsets.all(12),
            child: AppLoadingIndicator(
              color: theme.colorScheme.primary,
              constraints: BoxConstraints.tight(const Size(18, 18)),
            ),
          );
        } else if (value.text.isNotEmpty) {
          suffix = IconButton(
            tooltip: appText(context, english: 'Clear', arabic: 'مسح'),
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: () {
              _controller.clear();
              ref.read(searchSuggestionControllerProvider.notifier).clear();
              ref.read(searchQueryProvider.notifier).set('');
              _focusNode.requestFocus();
            },
          );
        }

        final field = AppSearchField(
          controller: _controller,
          focusNode: _focusNode,
          hintText: searchPlaceholder,
          textDirection: searchTextDirection(
            value.text,
            fallback: fieldDirection,
          ),
          onChanged: (val) {
            ref
                .read(searchSuggestionControllerProvider.notifier)
                .onQueryChanged(val);
          },
          onSubmitted: _submitSearch,
          suffixIcon: suffix,
        );
        return field;
      },
    );
  }

  /// A phone: neither a desktop nor a tablet-sized screen.
  bool _isPhone(BuildContext context) =>
      !ResponsiveBreakpoints.isDesktopPlatform() &&
      MediaQuery.sizeOf(context).shortestSide < 600;

  Widget _buildMobileLayout(BuildContext context) {
    final usePersistentGlass = appleUsesPersistentLiquidGlassHeader;
    // Results of a search are on screen: back returns to the search page.
    final searched = ref.watch(searchQueryProvider).trim().isNotEmpty;

    // The chips ride in the bar rather than below it, so they stay put while
    // the results scroll under both.
    final capabilities = ref.watch(searchDomainProvider).capabilities;
    final activeFilterCount = capabilities.showFilter
        ? ref.watch(searchProviderFiltersProvider).count
        : 0;
    const chipsHeight = 44.0;
    final barExtent =
        MediaQuery.paddingOf(context).top +
        kToolbarHeight +
        (activeFilterCount > 0 ? chipsHeight : 0);

    final scaffold = Scaffold(
      // Nothing is painted behind the bar: the results show through it as
      // they scroll past, the way the desktop one behaves.
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const AppProgressiveHeaderBackdrop(),
        bottom: activeFilterCount == 0
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(chipsHeight),
                child: _ActiveSearchFilterChips(
                  filters: ref.watch(searchProviderFiltersProvider),
                  onRemove: _removeSearchFilter,
                ),
              ),
        automaticallyImplyLeading: false,
        centerTitle: false,
        titleSpacing: 12,
        title: Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              // The side menu's button, in the corner the menu comes from —
              // or, showing a search's results, the way back to the page.
              if (searched)
                IconButton(
                  key: const ValueKey<String>('search-results-back'),
                  tooltip: appText(context, english: 'Back', arabic: 'رجوع'),
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: _backToSearchPage,
                )
              else
                const AppSideMenuButton(padding: EdgeInsets.only(right: 8)),
              Expanded(child: _buildMobileSearchField(context)),
              const SizedBox(width: 2),
              _buildMobileSearchActionGroup(context),
              // Details pins its iOS toolbar 34pt from the trailing edge.
              // AppBar already contributes 12pt of title spacing, so reserve
              // the remaining 22pt here to put Search on the same coordinate.
              const SizedBox(width: 22),
            ],
          ),
        ),
      ),
      body: _buildBody(context, topInset: barExtent + 8),
    );

    // The system back gesture leaves a search's results for the search page
    // before it leaves the tab.
    final withBack = PopScope(
      canPop: !searched,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToSearchPage();
      },
      child: scaffold,
    );

    // These glass controls belong to this row, not the persistent overlay.
    if (!usePersistentGlass) return withBack;
    return ApplePersistentGlassHeaderScope(
      branchIndex: TaskbarDestination.search.branchIndex,
      trailingButtons: const <AppleLiquidGlassToolbarButton>[],
      child: withBack,
    );
  }

  /// How far the floating search controls reach down the window. Content
  /// starts below this and scrolls up under it.
  static const double _floatingHeaderExtent = 56;

  Widget _buildBody(
    BuildContext context, {
    bool withFilterChips = false,
    double topInset = 0,
    bool behindPanel = false,
  }) {
    final state = ref.watch(searchPagedResultsProvider);
    final domain = ref.watch(searchDomainProvider);
    final suggestionState = ref.watch(searchSuggestionControllerProvider);
    final typedLongEnough = suggestionState.query.trim().length >= 2;
    // Typed but not yet searched: the floating results, in every category
    // but characters — with "no results" in them rather than the catalogue
    // that an empty search browses.
    final phone = _isPhone(context);
    final showSuggestions =
        !behindPanel &&
        !phone &&
        domain != SearchDomain.characters &&
        typedLongEnough &&
        ref.watch(searchQueryProvider).trim() != suggestionState.query.trim();

    // Only the results scroll, so every other state is simply held clear of
    // the floating controls rather than passing under them.
    final chips = withFilterChips && domain.capabilities.showFilter
        ? _ActiveSearchFilterChips(
            filters: ref.watch(searchProviderFiltersProvider),
            onRemove: _removeSearchFilter,
          )
        : const SizedBox.shrink();

    Widget belowHeader(Widget child) => Padding(
      padding: EdgeInsets.only(top: topInset),
      child: withFilterChips
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                chips,
                Expanded(child: child),
              ],
            )
          : child,
    );

    // Typed but not searched — one letter, or anything on a phone, which
    // searches on Enter: the search page stays.
    if (!showSuggestions &&
        !behindPanel &&
        domain != SearchDomain.characters &&
        _controller.text.trim().isNotEmpty &&
        (phone
            ? ref.watch(searchQueryProvider).trim() != _controller.text.trim()
            : ref.watch(searchQueryProvider).isEmpty)) {
      final page = _buildStartPage(context, typing: true);
      // Behind the box: the search page, or what was searched last.
      final base = page != null
          ? belowHeader(page)
          : phone
          ? _buildBody(
              context,
              withFilterChips: withFilterChips,
              topInset: topInset,
              behindPanel: true,
            )
          : belowHeader(const SizedBox.shrink());
      // On a phone, a box of the first results drops under the field; the
      // page stays in view below it.
      if (!phone || suggestionState.query.trim().length < 2) return base;
      final everything = <MultimediaItem>[
        ...suggestionState.items,
        ...suggestionState.animation,
        ...suggestionState.manga,
      ];
      return Stack(
        fit: StackFit.expand,
        children: [
          base,
          Positioned(
            top: topInset - 4,
            left: 12,
            right: 12,
            child: PhoneSuggestionBox(
              query: suggestionState.query.trim(),
              items: everything,
              loading: suggestionState.isLoading,
              onOpen: (item) => item.contentType == MultimediaContentType.manga
                  ? MangaDetailsRoute(
                      $extra: MangaDetailsRouteExtra(item: item),
                    ).push<void>(context)
                  : DetailsRoute($extra: DetailsRouteExtra(item: item))
                        .push<void>(context),
              onSeeAll: () => _submitSearch(_controller.text),
            ),
          ),
        ],
      );
    }

    if (showSuggestions) {
      // The results float over the search page, which stays behind them
      // dimmed; a click outside or Esc closes them.
      // Behind the panel: the search page, or what was last searched.
      final page = _buildStartPage(context, typing: true);
      return Stack(
        fit: StackFit.expand,
        children: [
          if (page != null)
            belowHeader(page)
          else
            _buildBody(
              context,
              withFilterChips: withFilterChips,
              topInset: topInset,
              behindPanel: true,
            ),
          GestureDetector(
            key: const ValueKey<String>('search-results-barrier'),
            onTap: _closeResultsPanel,
            child: const ColoredBox(color: Color(0x8C000000)),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, topInset, 16, 16),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                // Sized to its results, up to three quarters of the window.
                constraints: BoxConstraints(
                  maxWidth: 820,
                  maxHeight: MediaQuery.sizeOf(context).height * 0.75,
                ),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, child) => Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, (1 - t) * -12),
                      child: child,
                    ),
                  ),
                  child: Material(
                    key: const ValueKey<String>('search-results-panel'),
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    elevation: 16,
                    shadowColor: Colors.black,
                    borderRadius: BorderRadius.circular(18),
                    clipBehavior: Clip.antiAlias,
                    child: _buildSuggestionsView(context, suggestionState),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // An empty box would browse the whole catalogue; it offers recent
    // searches and what is popular instead.
    final startPage = _buildStartPage(context);
    if (startPage != null) return belowHeader(startPage);

    if (domain == SearchDomain.characters) {
      if (state.characters.isEmpty && state.isLoading) {
        return belowHeader(
          const AnimeCatalogShimmer(characterCaptionSpace: true),
        );
      }
      if (state.characters.isEmpty && state.errorMessage != null) {
        return belowHeader(
          RecoverableNetworkState(
            onRetry: _retrySearch,
            onOpenDownloads: () => const DownloadsRoute().go(context),
          ),
        );
      }
      if (state.characters.isEmpty) {
        return belowHeader(_buildEmptyState(context));
      }

      return RepaintBoundary(
        child: CatalogDirection(
          child: CustomScrollView(
            controller: _resultsScrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: topInset)),
              _characterGrid(
                context,
                state.characters,
                loadingMore: state.isLoadingMore,
              ),
            ],
          ),
        ),
      );
    }

    if (domain == SearchDomain.all) {
      return _buildAllBody(context, state, topInset: topInset);
    }

    final allResults = state.results.expand((entry) => entry.results).toList();
    if (allResults.isEmpty && state.isLoading) {
      return belowHeader(_buildLoadingIndicator(context));
    }
    if (allResults.isEmpty && state.errorMessage != null) {
      return belowHeader(
        RecoverableNetworkState(
          onRetry: _retrySearch,
          onOpenDownloads: () => const DownloadsRoute().go(context),
        ),
      );
    }
    if (allResults.isEmpty) {
      return belowHeader(_buildEmptyState(context));
    }

    return RepaintBoundary(
      child: CatalogDirection(
        child: CustomScrollView(
          controller: _resultsScrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: topInset)),
            if (withFilterChips) SliverToBoxAdapter(child: chips),
            for (var index = 0; index < state.results.length; index++)
              SearchResultSection(
                key: ValueKey(state.results[index].providerId),
                providerName: state.results[index].providerName,
                providerId: state.results[index].providerId,
                results: state.results[index].results,
                isLoadingMore:
                    state.isLoadingMore && index == state.results.length - 1,
                firstCardFocusNode: index == 0 ? _firstResultFocusNode : null,
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  /// How many of each category "all" shows before its "see all" button:
  /// a few full rows at the grid's own width, so no section ends on a
  /// half-filled line.
  int _allSectionLimit(BuildContext context) {
    final isLarge =
        ResponsiveBreakpoints.isDesktopPlatform() || context.isTabletOrLarger;
    if (!isLarge) {
      final columns = context.isHandsetLandscape
          ? ResponsiveBreakpoints.handsetLandscapeAnimeColumns
          : MultimediaCardLayout.handsetPortraitGridColumns;
      return columns * 2;
    }
    final size = MediaQuery.sizeOf(context);
    if (size.width > size.height) {
      return ResponsiveBreakpoints.desktopLandscapeColumnsForViewport(context) *
          2;
    }
    // An upright tablet shows a sliding rail, which any count fills.
    return 12;
  }

  /// Every category at once: each one that found something under its name,
  /// a few of its results, and a button into that category for the rest.
  Widget _buildAllBody(
    BuildContext context,
    SearchAggregateState state, {
    required double topInset,
  }) {
    final hasAny =
        state.characters.isNotEmpty ||
        state.results.any((entry) => entry.results.isNotEmpty);
    Widget clearOfHeader(Widget child) => Padding(
      padding: EdgeInsets.only(top: topInset),
      child: child,
    );
    if (!hasAny && state.isLoading) {
      return clearOfHeader(_buildLoadingIndicator(context));
    }
    if (!hasAny && state.errorMessage != null) {
      return clearOfHeader(
        RecoverableNetworkState(
          onRetry: _retrySearch,
          onOpenDownloads: () => const DownloadsRoute().go(context),
        ),
      );
    }
    if (!hasAny) return clearOfHeader(_buildEmptyState(context));

    final limit = _allSectionLimit(context);
    // The results are laid out left to right, the way posters read; the
    // headings keep the language's own direction.
    final textDirection = Directionality.of(context);
    Widget heading(SearchDomain domain) => SliverToBoxAdapter(
      child: Directionality(
        textDirection: textDirection,
        child: _AllSearchHeading(
          key: ValueKey<String>('search-all-heading-${domain.name}'),
          label: searchDomainLabel(context, domain),
          icon: searchDomainIcon(domain),
          onSeeAll: () => _selectSearchDomain(domain),
        ),
      ),
    );

    return RepaintBoundary(
      child: CatalogDirection(
        child: CustomScrollView(
          controller: _resultsScrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: topInset)),
            for (var index = 0; index < state.results.length; index++) ...[
              heading(
                SearchDomain.values.byName(state.results[index].providerId),
              ),
              SearchResultSection(
                key: ValueKey('search-all-${state.results[index].providerId}'),
                providerName: state.results[index].providerName,
                providerId: state.results[index].providerId,
                results: state.results[index].results
                    .take(limit)
                    .toList(growable: false),
                isLoadingMore: false,
                firstCardFocusNode: index == 0 ? _firstResultFocusNode : null,
              ),
            ],
            if (state.characters.isNotEmpty) ...[
              heading(SearchDomain.characters),
              _characterGrid(
                context,
                state.characters.take(limit).toList(growable: false),
                loadingMore: false,
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 100)),
          ],
        ),
      ),
    );
  }

  Widget _characterGrid(
    BuildContext context,
    List<AnimeWitcherCharacterHit> characters, {
    required bool loadingMore,
  }) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        MultimediaCardLayout.catalogGridHorizontalPadding(context),
        10,
        MultimediaCardLayout.catalogGridHorizontalPadding(context),
        100,
      ),
      sliver: SliverGrid(
        gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
          context,
          maxCrossAxisExtent: 140,
          childAspectRatio: MultimediaCardLayout.characterGridAspectRatio,
          crossAxisSpacing: MultimediaCardLayout.catalogGridCrossAxisSpacing(
            context,
            fallback: 12,
          ),
          mainAxisSpacing: MultimediaCardLayout.catalogGridMainAxisSpacing(
            context,
            fallback: 14,
          ),
          handsetPortraitCrossAxisCount:
              MultimediaCardLayout.handsetPortraitGridColumns,
          horizontalPadding: MultimediaCardLayout.catalogGridHorizontalPadding(
            context,
          ),
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index >= characters.length) {
              return const AnimePosterShimmer();
            }
            final character = characters[index];
            return CharacterPosterCard(
              key: ValueKey('search-character-${character.id}'),
              character: character,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CharacterDetailsScreen(
                      characterId: character.id,
                      initialName: character.name,
                      initialImageUrl: character.imageUrl,
                    ),
                  ),
                );
              },
            );
          },
          childCount:
              characters.length +
              (loadingMore
                  ? MultimediaCardLayout.handsetPortraitGridColumns
                  : 0),
        ),
      ),
    );
  }

  Widget _buildLoadingIndicator(BuildContext context) {
    return const AnimeCatalogShimmer();
  }

  Widget _buildSuggestionsView(
    BuildContext context,
    SearchSuggestionState suggestionState,
  ) {
    final items = suggestionState.items;
    if (!suggestionState.hasResults && suggestionState.isLoading) {
      // A spinner, not the catalogue's poster placeholders, which need a
      // page's height and are cut off in the panel.
      return SizedBox(
        height: 120,
        child: Center(
          child: AppLoadingIndicator(
            color: Theme.of(context).colorScheme.primary,
            constraints: BoxConstraints.tight(const Size(28, 28)),
          ),
        ),
      );
    }

    if (!suggestionState.hasResults) {
      return SizedBox(
        height: 160,
        child: Center(
          child: Text(
            appText(
              context,
              english: 'No results found',
              arabic: 'لم يتم العثور على نتائج',
            ),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    // The best match, the rest of its series, then series and films — the
    // way Harbor answers a search as it is typed.
    // Searching manga alone, its results are manga, not anime series.
    final mangaOnly = ref.read(searchDomainProvider) == SearchDomain.manga;
    return SearchInstantResults(
      items: mangaOnly ? const <MultimediaItem>[] : items,
      animation: suggestionState.animation,
      manga: mangaOnly ? items : suggestionState.manga,
      characters: suggestionState.characters,
      onOpenCharacter: (character) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CharacterDetailsScreen(
            characterId: character.id,
            initialName: character.name,
            initialImageUrl: character.imageUrl,
          ),
        ),
      ),
      loading: suggestionState.isLoading,
      firstFocusNode: _firstSuggestionFocusNode,
      onOpen: (item) => item.contentType == MultimediaContentType.manga
          ? MangaDetailsRoute($extra: MangaDetailsRouteExtra(item: item))
                .push<void>(context)
          : DetailsRoute($extra: DetailsRouteExtra(item: item))
                .push<void>(context),
      onSeeAll: () => _submitSearch(_controller.text),
      onClose: _closeResultsPanel,
    );
  }

  /// Saved as a favourite or to watch later, and never played: from the
  /// library, less anything with watch history.
  List<MultimediaItem> _savedNotStarted() {
    ref.watch(accountDataRevisionProvider);
    ref.watch(continueWatchingProvider);
    try {
      final library = ref.read(libraryRepositoryProvider);
      final history = ref.read(historyRepositoryProvider);
      final watched = <String>{
        for (final entry in history.getWatchHistory()) entry.item.url,
        for (final entry in history.getContinueWatching()) entry.item.url,
      };
      final seen = <String>{};
      return <MultimediaItem>[
        for (final category in const [
          LibraryCategory.planToWatch,
          LibraryCategory.favorite,
        ])
          for (final item in library.getLibraryItems(category: category))
            if (item.contentType != MultimediaContentType.manga &&
                !watched.contains(item.url) &&
                seen.add(item.url))
              item,
      ].take(20).toList(growable: false);
    } catch (_) {
      return const <MultimediaItem>[];
    }
  }

  /// A ranking as a whole page, loading on as it scrolls.
  void _openRanking(
    BuildContext context,
    MalRanking ranking,
    List<MultimediaItem> first,
  ) {
    final load = ref.read(malRankingLoaderProvider);
    void open(MultimediaItem item) =>
        DetailsRoute($extra: DetailsRouteExtra(item: item)).push<void>(context);
    ViewAllRoute(
      $extra: ViewAllRouteExtra(
        title: ranking == MalRanking.topMovies
            ? appText(context, english: 'Top movies', arabic: 'أفضل الأفلام')
            : appText(context, english: 'Top rated', arabic: 'الأعلى تقييمًا'),
        initialMediaList: first,
        category: ViewAllCategory.providerContent,
        onTap: open,
        loadPage: (offset) => load(ranking, offset),
        forcePortrait: true,
      ),
    ).push<void>(context);
  }

  bool _surprising = false;

  /// Opens a random anime from MyAnimeList's two hundred best rated that the
  /// catalogue carries; with MyAnimeList out of reach, one from home's rows.
  Future<void> _surpriseMe() async {
    if (_surprising) return;
    setState(() => _surprising = true);
    final random = math.Random();
    MultimediaItem? pick;
    try {
      final load = ref.read(malRankingLoaderProvider);
      for (var attempt = 0; attempt < 3 && pick == null; attempt++) {
        final page = await load(
          MalRanking.top,
          random.nextInt(8) * malRankingPageSize,
        );
        if (page.items.isNotEmpty) {
          pick = page.items[random.nextInt(page.items.length)];
        }
      }
    } catch (_) {}
    if (pick == null) {
      final home = ref.read(homeDataProvider);
      if (home is HomeSuccess) {
        final all = home.data.values.expand((items) => items).toList();
        if (all.isNotEmpty) pick = all[random.nextInt(all.length)];
      }
    }
    if (!mounted) return;
    setState(() => _surprising = false);
    if (pick == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            appText(
              context,
              english: "Couldn't pick one right now. Try again.",
              arabic: 'تعذر الاختيار الآن، حاول مرة أخرى.',
            ),
          ),
        ),
      );
      return;
    }
    await DetailsRoute($extra: DetailsRouteExtra(item: pick))
        .push<void>(context);
  }

  Widget _buildEmptyState(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final isInputEmpty = _controller.text.trim().isEmpty;

    if (query.isEmpty || isInputEmpty) {
      final recents = ref.watch(recentSearchesProvider);
      final domain = ref.watch(searchDomainProvider);
      // Before anything is typed: recent searches and what is popular.
      // Characters are only found by name.
      if (domain != SearchDomain.characters) {
        return _buildStartPage(context) ?? _buildSearchInvitation(context);
      }
      // What you searched for last is more useful than an invitation to
      // search, so it takes the placeholder's place when there is any.
      if (recents.isNotEmpty) {
        return RecentSearchesView(
          searches: recents,
          onSelected: _submitSearch,
          onRemoved: (value) =>
              ref.read(recentSearchesProvider.notifier).remove(value),
          onClearAll: () => ref.read(recentSearchesProvider.notifier).clear(),
        );
      }
      return _buildSearchInvitation(context);
    }
    return Center(
      child: Text(
        appText(
          context,
          english: 'No Results Found',
          arabic: 'لم يتم العثور على نتائج',
        ),
        style: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// Recent searches and what is popular, for an empty search box, in place
  /// of browsing the whole catalogue. Null where they do not belong:
  /// something typed, filters set, or characters, which are only found by
  /// name.
  Widget? _buildStartPage(
    BuildContext context, {
    double topPadding = 0,
    bool typing = false,
  }) {
    // While typing, the page shows behind the floating results.
    if ((!typing && _controller.text.trim().isNotEmpty) ||
        ref.watch(searchQueryProvider).isNotEmpty ||
        ref.watch(searchProviderFiltersProvider).isNotEmpty) {
      return null;
    }
    final domain = ref.watch(searchDomainProvider);
    if (domain == SearchDomain.characters) return null;
    final recents = ref.watch(recentSearchesProvider);
    // The anime rows; manga has none of its own yet.
    final anime = domain != SearchDomain.manga;
    final topRated = anime
        ? ref.watch(malRankingProvider(MalRanking.top)).value ??
              const <MultimediaItem>[]
        : const <MultimediaItem>[];
    final topMovies = anime
        ? ref.watch(malRankingProvider(MalRanking.topMovies)).value ??
              const <MultimediaItem>[]
        : const <MultimediaItem>[];
    final page = SearchStartPage(
      recents: recents,
      onRecent: _submitSearch,
      onRemoveRecent: (value) =>
          ref.read(recentSearchesProvider.notifier).remove(value),
      onClearRecents: () => ref.read(recentSearchesProvider.notifier).clear(),
      topPadding: topPadding,
      topTen: anime
          ? ref.watch(malTopTenProvider).value ?? const <MultimediaItem>[]
          : const <MultimediaItem>[],
      notStarted: anime ? _savedNotStarted() : const <MultimediaItem>[],
      topRated: topRated.take(20).toList(growable: false),
      onTopRatedViewAll: topRated.isEmpty
          ? null
          : () => _openRanking(context, MalRanking.top, topRated),
      topMovies: topMovies.take(20).toList(growable: false),
      onTopMoviesViewAll: topMovies.isEmpty
          ? null
          : () => _openRanking(context, MalRanking.topMovies, topMovies),
      onOpen: (item) =>
          DetailsRoute($extra: DetailsRouteExtra(item: item))
              .push<void>(context),
    );
    if (page.hasAnything) return page;
    return _buildSearchInvitation(context);
  }

  Widget _buildSearchInvitation(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.movie_filter_rounded,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant
                .withValues(alpha: 0.65),
          ),
          const SizedBox(height: LayoutConstants.spacingMd),
          Text(
            l10n.searchFavoriteContent,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.pressSearchOrEnter,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveSearchFilterChips extends StatelessWidget {
  final ProviderSearchFilters filters;
  final void Function(String group, String value) onRemove;

  const _ActiveSearchFilterChips({
    required this.filters,
    required this.onRemove,
  });

  List<(String, String)> get _items => [
    ...filters.genres.map((value) => ('genres', value)),
    ...filters.years.map((value) => ('years', value)),
    ...filters.seasons.map((value) => ('seasons', value)),
    ...filters.ageRatings.map((value) => ('ageRatings', value)),
    ...filters.types.map((value) => ('types', value)),
    ...filters.statuses.map((value) => ('statuses', value)),
  ];

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 14,
                        end: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: Text(
                              item.$2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.onPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                            padding: EdgeInsets.zero,
                            splashRadius: 15,
                            tooltip: appText(
                              context,
                              english: 'Remove filter',
                              arabic: 'إزالة الفلتر',
                            ),
                            icon: Icon(
                              Icons.close_rounded,
                              size: 18,
                              color: colors.onPrimary,
                            ),
                            onPressed: () => onRemove(item.$1, item.$2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The name of one category in the "all" results, with a way into the
/// whole of it.
class _AllSearchHeading extends StatelessWidget {
  const _AllSearchHeading({
    super.key,
    required this.label,
    required this.icon,
    required this.onSeeAll,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        MultimediaCardLayout.catalogGridHorizontalPadding(context),
        20,
        MultimediaCardLayout.catalogGridHorizontalPadding(context),
        0,
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          // The same pill as home's rows.
          HomeViewAllButton(onTap: onSeeAll),
        ],
      ),
    );
  }
}
