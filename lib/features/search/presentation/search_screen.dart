import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/core/navigation/taskbar_destination.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../core/providers/device_info_provider.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../home/presentation/widgets/provider_search_filter_dialog.dart';
import 'search_provider.dart';
import 'search_text_direction.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'widgets/search_result_section.dart';
import 'widgets/search_header_bar.dart';
import 'widgets/search_sort_dialog.dart';
import 'widgets/bouncy_entry_animation.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';

import 'package:skystream/core/utils/localized_text.dart';
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
  int _nativeFocusGeneration = 0;

  @override
  void initState() {
    super.initState();
    // Restore any previously committed query into the text field.
    _controller.text = ref.read(searchQueryProvider);
    _clearRequestSub = ref.listenManual<int>(
      searchClearRequestProvider,
      (previous, next) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _controller.clear();
        });
      },
    );
    _focusRequestSub = ref.listenManual<int>(
      searchFocusRequestProvider,
      (previous, next) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _requestSearchFocus();
          final textLength = _controller.text.length;
          _controller.selection = TextSelection.collapsed(offset: textLength);
        });
      },
    );
    _controller.addListener(_onTextChanged);
    _resultsScrollController.addListener(_onResultsScroll);
    ref.read(searchFilterProvider.notifier).set(SearchFilter.content);

    _focusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent) {
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          if (_controller.text.isNotEmpty &&
              _controller.selection.extentOffset == _controller.text.length) {
            _clearButtonFocusNode.requestFocus();
            return KeyEventResult.handled;
          }
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          final suggestionState = ref.read(searchSuggestionControllerProvider);
          final hasSuggestions = suggestionState.query.trim().length >= 2 &&
              (suggestionState.isLoading || suggestionState.suggestions.isNotEmpty);
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
          final hasSuggestions = suggestionState.query.trim().length >= 2 &&
              (suggestionState.isLoading || suggestionState.suggestions.isNotEmpty);
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
    final profile = ref.read(deviceProfileProvider).asData?.value;
    final usesNativeMobileSearch = appleUsesPersistentLiquidGlassHeader &&
        profile?.isTv != true &&
        !context.isTabletOrLarger;
    if (usesNativeMobileSearch) {
      _nativeFocusGeneration++;
      if (mounted) setState(() {});
      return;
    }
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

  Set<String> _readNativeFilterSet(Map<String, dynamic> value, String key) {
    final raw = value[key];
    if (raw is! List) return <String>{};
    return raw
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toSet();
  }

  ProviderSearchFilters _nativeFiltersToModel(
    Map<String, dynamic> value,
    String sort,
  ) {
    return ProviderSearchFilters(
      statuses: _readNativeFilterSet(value, 'statuses'),
      types: _readNativeFilterSet(value, 'types'),
      ageRatings: _readNativeFilterSet(value, 'ageRatings'),
      years: _readNativeFilterSet(value, 'years'),
      seasons: _readNativeFilterSet(value, 'seasons'),
      genres: _readNativeFilterSet(value, 'genres'),
      sort: sort,
    );
  }

  Future<void> _showSearchFilters() async {
    if (_isLoadingProviderFilters) return;
    final providers = ref
        .read(extensionManagerProvider.notifier)
        .getAllProviders();
    if (providers.isEmpty) return;

    setState(() => _isLoadingProviderFilters = true);
    ProviderSearchFilters? selected;
    try {
      final options = await providers.first.getSearchFilterOptions();
      if (!mounted) return;
      if (options.isEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                Localizations.localeOf(context).languageCode == 'ar'
                    ? 'لا توجد فلاتر متاحة'
                    : 'No filters available',
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        return;
      }

      // Use the exact same filter surface as the Home page so both entry
      // points have identical tabs, spacing, selection behavior, and glass.
      selected = await showDialog<ProviderSearchFilters>(
        context: context,
        builder: (dialogContext) => ProviderSearchFilterDialog(
          options: options,
          initialValue: ref.read(searchProviderFiltersProvider),
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoadingProviderFilters = false);
    }

    if (!mounted || selected == null) return;
    _resetResultsScrollPosition();
    ref.read(searchProviderFiltersProvider.notifier).set(selected);
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
        ),
    ];
  }

  String _searchSortSystemImage(SearchSortOption option) {
    return switch (option) {
      SearchSortOption.mostFavorited => 'star.fill',
      SearchSortOption.productionDateAscending => 'arrow.up',
      SearchSortOption.productionDateDescending => 'arrow.down',
      SearchSortOption.nameAscending => 'skystream.abc',
      SearchSortOption.nameDescending => 'skystream.zyx',
    };
  }

  IconData _searchSortFallbackIcon(SearchSortOption option) {
    return switch (option) {
      SearchSortOption.mostFavorited => Icons.star_rounded,
      SearchSortOption.productionDateAscending => Icons.arrow_upward_rounded,
      SearchSortOption.productionDateDescending => Icons.arrow_downward_rounded,
      SearchSortOption.nameAscending => Icons.sort_by_alpha_rounded,
      SearchSortOption.nameDescending => Icons.sort_by_alpha_rounded,
    };
  }

  Future<void> _showSearchSort() async {
    final current = ref.read(searchProviderFiltersProvider);
    String? selected;
    var nativeFailed = false;
    final nativeAvailable = await appleNativeLiquidGlassAvailable();

    if (nativeAvailable && mounted) {
      try {
        selected = await showAppleNativeSearchSort(
          initialValue: current.sort,
          isArabic:
              Localizations.localeOf(context).languageCode.toLowerCase() ==
              'ar',
          tintColor: Theme.of(context).colorScheme.primary,
          items: SearchSortOption.values
              .map(
                (option) => <String, String>{
                  'value': option.value,
                  'label': option.label(context),
                },
              )
              .toList(growable: false),
        );
        if (!mounted || selected == null) return;
      } on PlatformException {
        nativeFailed = true;
      } on MissingPluginException {
        nativeFailed = true;
      }
    }

    if (!nativeAvailable || nativeFailed) {
      selected = await showDialog<String>(
        context: context,
        useSafeArea: true,
        barrierColor: Colors.black.withValues(alpha: 0.22),
        builder: (_) => SearchSortDialog(initialValue: current.sort),
      );
      if (selected == null || !mounted) return;
    }

    final selectedValue = selected;
    if (selectedValue == null || !mounted) return;
    _applySearchSort(selectedValue);
  }

  void _resetResultsScrollPosition() {
    if (_resultsScrollController.hasClients) {
      _resultsScrollController.jumpTo(0);
    }
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
    // Keep the field focused after Search/Enter. The app-wide scroll behavior
    // dismisses the keyboard only when the user starts dragging a scroll view.
  }

  void _fillSuggestion(String suggestion) {
    _controller.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
    ref
        .read(searchSuggestionControllerProvider.notifier)
        .onQueryChanged(suggestion);
    _requestSearchFocus();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv == true || context.isTv;
    final isWidescreen = isTv || context.isTabletOrLarger;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (isWidescreen) {
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Stack(
          children: [
            // Cinematic Background Image - Local Asset (Dark Mode only)
            if (isDark)
              Positioned.fill(
                child: Image.asset(
                  'assets/images/search_background.jpg',
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              ),
            // Rich Architectural Stage Overlay (Vignette + Dark overlay - Dark Mode only)
            if (isDark)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(
                      alpha: 0.7,
                    ), // Rich dark overlay
                  ),
                ),
              ),
            // Radial Vignette Overlay centered on search area (Dark Mode only)
            if (isDark)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 1.1,
                      colors: [
                        Colors.black.withValues(alpha: 0.1),
                        Colors.black.withValues(alpha: 0.85),
                        Colors.black.withValues(alpha: 0.98),
                      ],
                      stops: const [0.0, 0.65, 1.0],
                    ),
                  ),
                ),
              ),
            // Left-to-right fade to blend backdrop image with the sidebar / background (Dark Mode only)
            if (isDark)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 320, // Wide fanning width to ease the transition
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          theme.scaffoldBackgroundColor,
                          theme.scaffoldBackgroundColor.withValues(alpha: 0.85),
                          theme.scaffoldBackgroundColor.withValues(alpha: 0.50),
                          theme.scaffoldBackgroundColor.withValues(alpha: 0.18),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.25, 0.55, 0.8, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            // Top-to-bottom edge vignette to mask out top/bottom image boundaries/black letterboxing (Dark Mode only)
            if (isDark)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          theme.scaffoldBackgroundColor,
                          theme.scaffoldBackgroundColor.withValues(alpha: 0.8),
                          Colors.transparent,
                          Colors.transparent,
                          theme.scaffoldBackgroundColor.withValues(alpha: 0.8),
                          theme.scaffoldBackgroundColor,
                        ],
                        stops: const [0.0, 0.08, 0.2, 0.8, 0.92, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            // Focus Spotlight (Stage Lighting - Soft fanning semi-circle)
            Positioned(
              top:
                  76, // Anchored immediately below the search bar (24 top padding + 52 height)
              left: 0,
              right: 0,
              height: 250,
              child: ListenableBuilder(
                listenable: _focusNode,
                builder: (context, child) {
                  if (!_focusNode.hasFocus) return const SizedBox.shrink();
                  final spotlightColor = theme.colorScheme.primary;
                  return IgnorePointer(
                    child: Center(
                      child: Container(
                        width: 900, // Broader fanning footprint
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: Alignment
                                .topCenter, // Fanning downward from the bottom edge of the search bar
                            radius: 1.3,
                            colors: [
                              spotlightColor.withValues(
                                alpha: isDark ? 0.35 : 0.22,
                              ), // Soft center source point
                              spotlightColor.withValues(
                                alpha: isDark ? 0.18 : 0.10,
                              ), // Smooth bleed
                              spotlightColor.withValues(
                                alpha: isDark ? 0.06 : 0.03,
                              ), // Gentle falloff
                              spotlightColor.withValues(
                                alpha: 0.0,
                              ), // Fade to transparent
                            ],
                            stops: const [0.0, 0.35, 0.70, 1.0],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // Content layout in Column: Still header and Body directly below it
            Positioned.fill(
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  SearchHeaderBar(
                    textController: _controller,
                    searchFocusNode: _focusNode,
                    clearButtonFocusNode: _clearButtonFocusNode,
                    isCompact: false,
                    onShowFilters: _showSearchFilters,
                    onShowSort: _showSearchSort,
                    onSortSelected: _applySearchSort,
                    sortValue: ref.watch(searchProviderFiltersProvider).sort,
                    sortItems: _searchSortMenuItems(context),
                    sortTooltip:
                        '${appText(context, english: 'Sort by', arabic: 'الترتيب حسب')}: '
                        '${SearchSortOption.fromValue(ref.watch(searchProviderFiltersProvider).sort).label(context)}',
                    activeFilterCount: ref.watch(searchProviderFiltersProvider).count,
                    isFilterLoading: _isLoadingProviderFilters,
                    onSubmitted: _submitSearch,
                    onChanged: (val) {
                      ref
                          .read(searchSuggestionControllerProvider.notifier)
                          .onQueryChanged(val);
                    },
                  ),
                  Expanded(
                    child: Padding(
                      // Fixed top padding below the top search bar (24px)
                      padding: const EdgeInsets.only(top: 24.0),
                      child: _buildBody(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Mobile layout: existing AppBar
    return _buildMobileLayout(context);
  }

  List<AppleLiquidGlassToolbarButton> _buildPersistentSearchButtons(
    BuildContext context,
  ) {
    final activeFilters = ref.watch(searchProviderFiltersProvider);
    final sortOption = SearchSortOption.fromValue(activeFilters.sort);
    final primary = Theme.of(context).colorScheme.primary;

    return <AppleLiquidGlassToolbarButton>[
      AppleLiquidGlassToolbarButton(
        width: 190,
        icon: _searchSortFallbackIcon(sortOption),
        systemImage: _searchSortSystemImage(sortOption),
        title: sortOption.label(context),
        tooltip:
            '${appText(context, english: 'Sort by', arabic: 'الترتيب حسب')}: ${sortOption.label(context)}',
        color: primary,
        menuTintColor: primary,
        onPressed: _showSearchSort,
        selectedMenuValue: activeFilters.sort,
        menuItems: _searchSortMenuItems(context),
        onMenuSelected: _applySearchSort,
      ),
      AppleLiquidGlassToolbarButton(
        width: 42,
        icon: Icons.tune_rounded,
        tooltip: appText(
          context,
          english: 'Filters',
          arabic: 'الفلاتر',
        ),
        color: primary,
        onPressed: _isLoadingProviderFilters ? null : _showSearchFilters,
      ),
    ];
  }

  Widget _buildMobileSearchActionGroup(BuildContext context) {
    final activeFilters = ref.watch(searchProviderFiltersProvider);
    final sortOption = SearchSortOption.fromValue(activeFilters.sort);
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

    return AppleSearchGlassActions(
      filterCount: activeFilters.count,
      isFilterLoading: _isLoadingProviderFilters,
      isArabic: isArabic,
      sortValue: activeFilters.sort,
      sortItems: _searchSortMenuItems(context),
      sortAccessibilityLabel:
          '${appText(context, english: 'Sort by', arabic: 'الترتيب حسب')}: ${sortOption.label(context)}',
      filterAccessibilityLabel: appText(
        context,
        english: 'Filters',
        arabic: 'الفلاتر',
      ),
      tintColor: Theme.of(context).colorScheme.primary,
      height: 42,
      onSortPressed: _showSearchSort,
      onSortSelected: _applySearchSort,
      onFilterPressed: _showSearchFilters,
    );
  }

  Widget _buildMobileLayout(BuildContext context) {
    final searchResultsState = ref.watch(searchPagedResultsProvider);
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final usePersistentGlass = appleUsesPersistentLiquidGlassHeader;
    final searchPlaceholder = isArabic ? 'Search...' : l10n.searchHint;
    const persistentSearchActionsWidth = 140.0;

    final scaffold = Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        leadingWidth: isArabic
            ? (usePersistentGlass ? persistentSearchActionsWidth + 10 : 104)
            : null,
        leading: isArabic
            ? Padding(
                padding: const EdgeInsets.only(right: 10),
                child: usePersistentGlass
                    ? const SizedBox(width: persistentSearchActionsWidth)
                    : _buildMobileSearchActionGroup(context),
              )
            : null,
        actions: isArabic
            ? null
            : [
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: usePersistentGlass
                      ? const SizedBox(width: persistentSearchActionsWidth)
                      : _buildMobileSearchActionGroup(context),
                ),
              ],
        title: usePersistentGlass
            ? AppleNativeGlassSearchField(
                controller: _controller,
                placeholder: searchPlaceholder,
                tintColor: theme.colorScheme.primary,
                textColor: theme.colorScheme.onSurface,
                placeholderColor: theme.colorScheme.onSurfaceVariant,
                focusRequest: _nativeFocusGeneration,
                loading: searchResultsState.isLoading,
                textDirection: searchTextDirection(
                  _controller.text,
                  fallback: Directionality.of(context),
                ),
                height: 46,
                onChanged: (val) {
                  ref
                      .read(searchSuggestionControllerProvider.notifier)
                      .onQueryChanged(val);
                },
                onSubmitted: _submitSearch,
              )
            : GestureDetector(
          onTap: () {
            if (!_focusNode.hasFocus) {
              _focusNode.requestFocus();
            }
          },
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 42,
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, child) {
                final isSearching = searchResultsState.isLoading;

                Widget? suffix;
                if (isSearching) {
                  suffix = Padding(
                    padding: const EdgeInsets.all(12),
                    child: AppLoadingIndicator(
                      color: theme.colorScheme.primary,
                      constraints: BoxConstraints.tight(const Size(18, 18)),
                    ),
                  );
                } else if (value.text.isNotEmpty) {
                  suffix = IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(32, 32),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () {
                      _controller.clear();
                      ref
                          .read(searchSuggestionControllerProvider.notifier)
                          .clear();
                      ref.read(searchQueryProvider.notifier).set('');
                    },
                  );
                }

                return TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: false,
                  style: TextStyle(
                    fontSize: 14,
                    color: theme.colorScheme.onSurface,
                  ),
                  textDirection: searchTextDirection(
                    _controller.text,
                    fallback: Directionality.of(context),
                  ),
                  textAlign: TextAlign.start,
                  textAlignVertical: TextAlignVertical.center,
                  textInputAction: TextInputAction.search,
                  enableInteractiveSelection: true,
                  contextMenuBuilder: (context, editableTextState) {
                    return AdaptiveTextSelectionToolbar.buttonItems(
                      anchors: editableTextState.contextMenuAnchors,
                      buttonItems: editableTextState.contextMenuButtonItems,
                    );
                  },
                  onChanged: (val) {
                    ref
                        .read(searchSuggestionControllerProvider.notifier)
                        .onQueryChanged(val);
                  },
                  onSubmitted: _submitSearch,
                  decoration: InputDecoration(
                    hintText: searchPlaceholder,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        LayoutConstants.radiusPill,
                      ),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        LayoutConstants.radiusPill,
                      ),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        LayoutConstants.radiusPill,
                      ),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 42,
                    ),
                    suffixIcon: suffix,
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 42,
                      minHeight: 42,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
      body: _buildBody(context),
    );

    if (!usePersistentGlass) return scaffold;
    return ApplePersistentGlassHeaderScope(
      branchIndex: TaskbarDestination.search.branchIndex,
      trailingButtons: _buildPersistentSearchButtons(context),
      child: scaffold,
    );
  }

  Widget _buildBody(BuildContext context) {
    final state = ref.watch(searchPagedResultsProvider);
    final suggestionState = ref.watch(searchSuggestionControllerProvider);
    final typedLongEnough = suggestionState.query.trim().length >= 2;
    final hasSuggestionContent =
        suggestionState.isLoading || suggestionState.suggestions.isNotEmpty;
    final showSuggestions = typedLongEnough && hasSuggestionContent;

    if (showSuggestions) {
      return _buildSuggestionsView(context, suggestionState);
    }

    final allResults = state.results.expand((entry) => entry.results).toList();
    if (allResults.isEmpty && state.isLoading) {
      return _buildLoadingIndicator(context);
    }
    if (allResults.isEmpty) {
      return _buildEmptyState(context);
    }

    return RepaintBoundary(
      child: ListView.builder(
        controller: _resultsScrollController,
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: state.results.length,
        itemBuilder: (context, index) {
          final pResult = state.results[index];
          return SearchResultSection(
            key: ValueKey(pResult.providerId),
            providerName: pResult.providerName,
            providerId: pResult.providerId,
            results: pResult.results,
            isLoadingMore:
                state.isLoadingMore && index == state.results.length - 1,
            firstCardFocusNode: index == 0 ? _firstResultFocusNode : null,
          );
        },
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
    if (suggestionState.isLoading) {
      return _buildLoadingIndicator(context);
    }

    if (suggestionState.suggestions.isEmpty) {
      return Center(
        child: Text(
          appText(context, english: 'No results found', arabic: 'لم يتم العثور على نتائج'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: suggestionState.suggestions.length,
      itemBuilder: (context, index) {
        final suggestion = suggestionState.suggestions[index];
        return BouncyEntryAnimation(
          delay: Duration(milliseconds: index * 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: _SuggestionCard(
              suggestion: suggestion,
              focusNode: index == 0 ? _firstSuggestionFocusNode : null,
              isFirst: index == 0,
              onFocusSearch: () => _focusNode.requestFocus(),
              onTap: () => _submitSearch(suggestion),
              onFill: () => _fillSuggestion(suggestion),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = ref.watch(searchQueryProvider);
    final isInputEmpty = _controller.text.trim().isEmpty;

    if (query.isEmpty || isInputEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.movie_filter_rounded,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
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
    final nativeFont = Theme.of(context).textTheme.bodyLarge?.fontFamily;
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv == true || context.isTv;
    final isWidescreen = isTv || context.isTabletOrLarger;
    final imageWidth = isWidescreen ? 320.0 : 200.0;

    // No search results found: display No Results Found text and the image grouped vertically
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            appText(context, english: 'No Results Found', arabic: 'لم يتم العثور على نتائج'),
            style: TextStyle(
              fontFamily: nativeFont,
              fontSize: 16.0,
              fontWeight: FontWeight.w400,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Image.asset(
            'assets/images/no_results.png',
            fit: BoxFit.contain,
            width: imageWidth,
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _SuggestionCard extends StatefulWidget {
  final String suggestion;
  final VoidCallback onTap;
  final VoidCallback onFill;
  final FocusNode? focusNode;
  final bool isFirst;
  final VoidCallback onFocusSearch;

  const _SuggestionCard({
    required this.suggestion,
    required this.onTap,
    required this.onFill,
    required this.isFirst,
    required this.onFocusSearch,
    this.focusNode,
  });

  @override
  State<_SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends State<_SuggestionCard> {
  bool _isBodyHovered = false;
  bool _isButtonHovered = false;

  late final FocusNode _bodyNode;
  late final FocusNode _buttonNode;

  @override
  void initState() {
    super.initState();
    _bodyNode = widget.focusNode ?? FocusNode();
    _bodyNode.addListener(_onFocusChange);
    _buttonNode = FocusNode();
    _buttonNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _bodyNode.dispose();
    } else {
      if (_bodyNode.hasFocus) {
        _bodyNode.unfocus();
      }
      _bodyNode.removeListener(_onFocusChange);
    }
    _buttonNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final nativeFont = theme.textTheme.bodyLarge?.fontFamily;

    final isBodyHighlighted = _isBodyHovered || _bodyNode.hasFocus;
    final isButtonHighlighted = _isButtonHovered || _buttonNode.hasFocus;
    final isAnyHighlighted = isBodyHighlighted || isButtonHighlighted;

    final baseBorderColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : theme.colorScheme.outlineVariant;
    final highlightColor = theme.colorScheme.primary;

    final borderColor = isAnyHighlighted
        ? highlightColor.withValues(alpha: 0.85)
        : baseBorderColor;

    final cardBgColor = isDark
        ? Colors.black.withValues(alpha: 0.65)
        : theme.colorScheme.surfaceContainer;

    final bodyHighlightBg = theme.colorScheme.primary.withValues(
      alpha: isDark ? 0.25 : 0.12,
    );

    final buttonHighlightBg = theme.colorScheme.primary.withValues(
      alpha: isDark ? 0.35 : 0.18,
    );

    final iconColor = isDark
        ? Colors.white70
        : theme.colorScheme.onSurfaceVariant;

    final textColor = isDark ? Colors.white : theme.colorScheme.onSurface;

    final buttonIconColor = isDark
        ? Colors.white54
        : theme.colorScheme.onSurfaceVariant;

    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : theme.colorScheme.outlineVariant;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: cardBgColor, // Theme-aware card background
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1.5),
        boxShadow: isAnyHighlighted
            ? [
                BoxShadow(
                  color: highlightColor.withValues(alpha: 0.2),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          // Main Body Focus (Search text)
          Expanded(
            child: Focus(
              focusNode: _bodyNode,
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent) {
                  if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                      widget.isFirst) {
                    widget.onFocusSearch();
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                    _buttonNode.requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.select ||
                      event.logicalKey == LogicalKeyboardKey.enter ||
                      event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                      event.logicalKey == LogicalKeyboardKey.space) {
                    widget.onTap();
                    return KeyEventResult.handled;
                  }
                }
                return KeyEventResult.ignored;
              },
              child: MouseRegion(
                onEnter: (_) => setState(() => _isBodyHovered = true),
                onExit: (_) => setState(() => _isBodyHovered = false),
                child: GestureDetector(
                  onTap: widget.onTap,
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: isBodyHighlighted
                          ? bodyHighlightBg
                          : Colors.transparent,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(11),
                        bottomLeft: Radius.circular(11),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.search_rounded,
                          color: isBodyHighlighted ? highlightColor : iconColor,
                          size: 20,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            widget.suggestion,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: nativeFont,
                              color: textColor,
                              fontSize: 16.0,
                              fontWeight: isBodyHighlighted
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Vertical divider line between text block and arrow button
          Container(width: 1.0, height: 24.0, color: dividerColor),
          // Fill Button Focus (Arrow icon button)
          Focus(
            focusNode: _buttonNode,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) {
                if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
                    widget.isFirst) {
                  widget.onFocusSearch();
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                  _bodyNode.requestFocus();
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.select ||
                    event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                    event.logicalKey == LogicalKeyboardKey.space) {
                  widget.onFill();
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: MouseRegion(
              onEnter: (_) => setState(() => _isButtonHovered = true),
              onExit: (_) => setState(() => _isButtonHovered = false),
              child: GestureDetector(
                onTap: widget.onFill,
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: isButtonHighlighted
                        ? buttonHighlightBg
                        : Colors.transparent,
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(11),
                      bottomRight: Radius.circular(11),
                    ),
                  ),
                  child: Icon(
                    Icons.north_west_rounded,
                    color: isButtonHighlighted
                        ? highlightColor
                        : buttonIconColor,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
