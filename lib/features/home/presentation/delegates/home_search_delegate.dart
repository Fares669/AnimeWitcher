import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:skystream/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../core/router/app_router.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../shared/widgets/anime_catalog_shimmer.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../../../search/presentation/search_provider.dart';
import '../widgets/provider_search_filter_dialog.dart';

import 'package:skystream/core/utils/localized_text.dart';
String homeSearchFieldLabel(
  BuildContext context,
  ProviderSearchFilters filters,
) {
  final isArabic =
      Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
  if (filters.isNotEmpty) {
    return isArabic
        ? 'ابحث ضمن النتائج المفلترة...'
        : 'Search within filtered results...';
  }
  return isArabic
      ? 'ابحث عن أفلام ومسلسلات...'
      : 'Search movies, series...';
}

class HomeSearchDelegate extends SearchDelegate<void> {
  final String? initialQuery;
  final bool openWithoutKeyboard;
  final ValueChanged<ProviderSearchFilters>? onFiltersChanged;

  ProviderSearchFilters _filters;
  ProviderSearchFilterOptions? _filterOptions;
  static const double _swipeBackDistanceThreshold = 80;
  static const double _swipeBackVelocityThreshold = 700;

  bool _loadingFilterOptions = false;
  bool _keyboardSuppressed = false;
  double _swipeBackDistance = 0;

  HomeSearchDelegate({
    this.initialQuery,
    ProviderSearchFilters filters = const ProviderSearchFilters(),
    String? searchFieldHint,
    this.openWithoutKeyboard = false,
    this.onFiltersChanged,
  }) : _filters = filters,
       super(
         searchFieldLabel:
             searchFieldHint ??
             (filters.isEmpty
                 ? 'Search movies, series...'
                 : 'Search within filtered results...'),
         searchFieldStyle: null,
       ) {
    if (initialQuery != null) {
      query = initialQuery!;
    }
  }

  ProviderSearchFilters get filters => _filters;

  Widget _buildSwipeBackRegion(BuildContext context, Widget child) {
    return SizedBox.expand(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => _swipeBackDistance = 0,
        onHorizontalDragUpdate: (details) {
          _swipeBackDistance += details.primaryDelta ?? 0;
        },
        onHorizontalDragCancel: () => _swipeBackDistance = 0,
        onHorizontalDragEnd: (details) {
          final distance = _swipeBackDistance;
          final velocity = details.primaryVelocity ?? 0;
          _swipeBackDistance = 0;

          final shouldClose =
              distance >= _swipeBackDistanceThreshold ||
              velocity >= _swipeBackVelocityThreshold;
          if (!shouldClose) return;

          _dismissKeyboard(context);
          close(context, null);
        },
        child: child,
      ),
    );
  }

  void _dismissKeyboard(BuildContext context) {
    FocusManager.instance.primaryFocus?.unfocus();
    FocusScope.of(context).unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  void _suppressInitialKeyboard(BuildContext context) {
    if (!openWithoutKeyboard || _keyboardSuppressed) return;
    _keyboardSuppressed = true;

    void hideAfter(Duration delay) {
      Future<void>.delayed(delay, () {
        if (context.mounted) _dismissKeyboard(context);
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      _dismissKeyboard(context);
      hideAfter(const Duration(milliseconds: 60));
      hideAfter(const Duration(milliseconds: 160));
      hideAfter(const Duration(milliseconds: 320));
    });
  }

  Future<void> _openFilters(BuildContext context) async {
    if (_loadingFilterOptions) return;

    final container = ProviderScope.containerOf(context, listen: false);
    final provider = container.read(activeProviderProvider);
    if (provider == null) return;

    _loadingFilterOptions = true;

    late ProviderSearchFilterOptions options;
    try {
      options = _filterOptions ?? await provider.getSearchFilterOptions();
      _filterOptions = options;
    } finally {
      _loadingFilterOptions = false;
    }

    if (!context.mounted) return;
    if (options.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              Localizations.localeOf(context).languageCode == 'ar'
                  ? 'هذه الإضافة لا توفر فلاتر بحث'
                  : 'This provider does not expose search filters',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }

    _dismissKeyboard(context);
    final selected = await showDialog<ProviderSearchFilters>(
      context: context,
      builder: (dialogContext) =>
          ProviderSearchFilterDialog(options: options, initialValue: _filters),
    );

    if (!context.mounted || selected == null) return;

    _filters = selected.copyWith(sort: _filters.sort);
    onFiltersChanged?.call(_filters);

    // Force SearchDelegate to rebuild even when it is already displaying
    // results. Toggling its body mode avoids requiring the user to focus or
    // submit the query again after changing filters.
    showSuggestions(context);
    _dismissKeyboard(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      showResults(context);
      _dismissKeyboard(context);
    });
  }

  @override
  ThemeData appBarTheme(BuildContext context) {
    final theme = Theme.of(context);
    return theme.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: theme.colorScheme.onSurface),
        toolbarHeight: 70,
      ),
      inputDecorationTheme: InputDecorationTheme(
        hintStyle: TextStyle(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        border: InputBorder.none,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: theme.colorScheme.primary,
        selectionColor: theme.colorScheme.primary.withValues(alpha: 0.3),
      ),
      textTheme: theme.textTheme.copyWith(
        titleMedium: TextStyle(
          color: theme.colorScheme.onSurface,
          fontSize: 18,
        ),
      ),
    );
  }

  Widget _buildFilterButton(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: Localizations.localeOf(context).languageCode == 'ar'
          ? 'فلاتر البحث'
          : 'Search filters',
      onPressed: _loadingFilterOptions ? null : () => _openFilters(context),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          _loadingFilterOptions
              ? SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                )
              : Icon(
                  Icons.tune_rounded,
                  color: _filters.isNotEmpty
                      ? colors.primary
                      : colors.onSurface,
                ),
          if (_filters.isNotEmpty && !_loadingFilterOptions)
            Positioned(
              right: -8,
              top: -8,
              child: Container(
                constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_filters.count}',
                  style: TextStyle(
                    color: colors.onPrimary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _applySort(BuildContext context, String sort) {
    if (_filters.sort == sort) return;
    _filters = _filters.copyWith(sort: sort);
    onFiltersChanged?.call(_filters);
    _dismissKeyboard(context);

    // Restart the paginated result body immediately with the selected
    // AnimeWitcher Algolia replica, without requiring a new search submit.
    showSuggestions(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      showResults(context);
      _dismissKeyboard(context);
    });
  }

  Widget _buildSortButton(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final colors = Theme.of(context).colorScheme;
    final current = _filters.sort;

    return PopupMenuButton<String>(
      tooltip: isArabic ? 'ترتيب الأنمي' : 'Sort anime',
      initialValue: current.isEmpty ? 'default' : current,
      onSelected: (value) =>
          _applySort(context, value == 'default' ? '' : value),
      icon: Icon(
        Icons.sort_rounded,
        color: current.isNotEmpty ? colors.primary : colors.onSurface,
      ),
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        CheckedPopupMenuItem<String>(
          value: 'default',
          checked: current.isEmpty,
          child: Text(isArabic ? 'الافتراضي' : 'Default'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'favorites',
          checked: current == 'favorites',
          child: Text(isArabic ? 'الأكثر تفضيلاً' : 'Most favorited'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'rating',
          checked: current == 'rating',
          child: Text(isArabic ? 'الأعلى تقييماً' : 'Top rated'),
        ),
        CheckedPopupMenuItem<String>(
          value: 'date_added',
          checked: current == 'date_added',
          child: Text(isArabic ? 'تاريخ الإضافة' : 'Date added'),
        ),
      ],
    );
  }

  Widget _buildBackButton(BuildContext context) {
    return AppleLiquidGlassBackButton(
      size: 42,
      onPressed: () => close(context, null),
    );
  }

  Widget _buildClearButton(BuildContext context) {
    return IconButton(
      tooltip: Localizations.localeOf(context).languageCode == 'ar'
          ? 'مسح البحث'
          : 'Clear search',
      icon: const Icon(Icons.clear),
      onPressed: () {
        query = '';
        showSuggestions(context);
      },
    );
  }

  @override
  List<Widget>? buildActions(BuildContext context) {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return [
      if (isRtl && query.isNotEmpty) _buildClearButton(context),
      if (isRtl) _buildBackButton(context) else _buildFilterButton(context),
      _buildSortButton(context),
      if (!isRtl && query.isNotEmpty) _buildClearButton(context),
      const SizedBox(width: 8),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    // Keep the same physical arrangement in every language: back on the
    // left and filters on the right. SearchDelegate mirrors these slots in RTL.
    return isRtl ? _buildFilterButton(context) : _buildBackButton(context);
  }

  @override
  Widget buildResults(BuildContext context) {
    _suppressInitialKeyboard(context);
    return _buildSwipeBackRegion(
      context,
      _HomeSearchResults(query: query, filters: _filters),
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    _suppressInitialKeyboard(context);

    final Widget child;
    if (query.isEmpty) {
      // Opening Search should immediately show AnimeWitcher's real anime
      // catalog instead of the home "latest added" replica or an empty page.
      child = _HomeSearchResults(query: query, filters: _filters);
    } else {
      child = _HomeSearchSuggestions(
        query: query,
        onSelect: (value) {
          query = value;
          showResults(context);
        },
      );
    }

    return _buildSwipeBackRegion(context, child);
  }
}

class _HomeSearchSuggestions extends ConsumerStatefulWidget {
  final String query;
  final void Function(String) onSelect;

  const _HomeSearchSuggestions({required this.query, required this.onSelect});

  @override
  ConsumerState<_HomeSearchSuggestions> createState() =>
      _HomeSearchSuggestionsState();
}

class _HomeSearchSuggestionsState
    extends ConsumerState<_HomeSearchSuggestions> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(searchSuggestionControllerProvider.notifier)
          .onQueryChanged(widget.query);
    });
  }

  @override
  void didUpdateWidget(covariant _HomeSearchSuggestions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      Future.microtask(() {
        if (!context.mounted) return;
        ref
            .read(searchSuggestionControllerProvider.notifier)
            .onQueryChanged(widget.query);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchSuggestionControllerProvider);
    final isLoading = searchState.isLoading;
    final suggestions = searchState.suggestions;

    if (isLoading) {
      return const AnimeCatalogShimmer();
    }

    if (suggestions.isEmpty) {
      return Center(
        child: Text(
          appText(context, english: 'No results found', arabic: 'لم يتم العثور على نتائج'),
          style: TextStyle(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: suggestions.length,
      itemBuilder: (context, index) {
        final suggestion = suggestions[index];
        return Material(
          type: MaterialType.transparency,
          child: ListTile(
            leading: const Icon(Icons.search_rounded),
            title: Text(suggestion),
            trailing: IconButton(
              tooltip: appText(context, english: 'Fill query', arabic: 'إدخال عبارة البحث'),
              icon: const Icon(Icons.north_west_rounded),
              onPressed: () => widget.onSelect(suggestion),
            ),
            onTap: () => widget.onSelect(suggestion),
          ),
        );
      },
    );
  }
}

class _HomeSearchResults extends ConsumerStatefulWidget {
  final String query;
  final ProviderSearchFilters filters;

  const _HomeSearchResults({required this.query, required this.filters});

  @override
  ConsumerState<_HomeSearchResults> createState() => _HomeSearchResultsState();
}

class _HomeSearchResultsState extends ConsumerState<_HomeSearchResults> {
  final ScrollController _scrollController = ScrollController();
  final List<MultimediaItem> _items = <MultimediaItem>[];
  final Set<String> _seen = <String>{};

  bool _isInitialLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  int _generation = 0;
  String? _providerId;
  Timer? _searchDebounce;
  CancelToken? _pageCancelToken;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _resetAndLoad();
  }

  @override
  void didUpdateWidget(covariant _HomeSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        oldWidget.filters.toJson().toString() !=
            widget.filters.toJson().toString()) {
      _resetAndLoad();
    }
  }

  @override
  void dispose() {
    _generation += 1;
    _searchDebounce?.cancel();
    _pageCancelToken?.cancel('Search screen disposed');
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 600) {
      _loadNextPage();
    }
  }

  void _resetAndLoad() {
    _generation += 1;
    _searchDebounce?.cancel();
    _pageCancelToken?.cancel('Search query changed');
    _pageCancelToken = null;
    setState(() {
      _items.clear();
      _seen.clear();
      _offset = 0;
      _hasMore = true;
      _isInitialLoading = true;
      _isLoadingMore = false;
      _providerId = null;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _loadNextPage();
    });
  }

  String _itemKey(MultimediaItem item) {
    final url = item.url.trim();
    if (url.isNotEmpty) return url;
    return '${item.id}|${item.title}|${item.posterUrl}';
  }

  Future<void> _loadNextPage() async {
    if (!_hasMore || _isLoadingMore) return;

    final provider = ref.read(activeProviderProvider);
    if (provider == null) {
      if (mounted) {
        setState(() {
          _isInitialLoading = false;
          _hasMore = false;
        });
      }
      return;
    }

    final generation = _generation;
    final requestedOffset = _offset;
    final requestToken = CancelToken();
    _pageCancelToken = requestToken;

    setState(() {
      _isLoadingMore = true;
      _providerId = provider.packageName;
    });

    try {
      final page = await provider.searchPage(
        widget.query,
        widget.filters,
        offset: requestedOffset,
        limit: provider.searchPageSize,
        cancelToken: requestToken,
      );

      if (!mounted || generation != _generation || requestToken.isCancelled) return;
      if (identical(_pageCancelToken, requestToken)) _pageCancelToken = null;

      for (final item in page.items) {
        if (_seen.add(_itemKey(item))) {
          _items.add(item);
        }
      }

      final fallbackAdvance = page.items.isNotEmpty ? page.items.length : 1;
      final nextOffset = page.nextOffset > requestedOffset
          ? page.nextOffset
          : requestedOffset + fallbackAdvance;

      setState(() {
        _offset = nextOffset;
        _hasMore = page.hasMore &&
            (page.nextOffset > requestedOffset || page.items.isNotEmpty);
        _isInitialLoading = false;
        _isLoadingMore = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureFilled());
    } catch (_) {
      if (!mounted || generation != _generation || requestToken.isCancelled) return;
      if (identical(_pageCancelToken, requestToken)) _pageCancelToken = null;
      setState(() {
        _isInitialLoading = false;
        _isLoadingMore = false;
        _hasMore = false;
      });
    }
  }

  void _ensureFilled() {
    if (!mounted || !_hasMore || _isLoadingMore) return;
    if (!_scrollController.hasClients ||
        _scrollController.position.maxScrollExtent <
            _scrollController.position.viewportDimension * 0.65) {
      _loadNextPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitialLoading && _items.isEmpty) {
      return const AnimeCatalogShimmer();
    }

    if (_items.isEmpty && !_hasMore) {
      final profile = ref.watch(deviceProfileProvider).asData?.value;
      final isTv = profile?.isTv == true || context.isTv;
      final isWidescreen = isTv || context.isTabletOrLarger;
      final imageWidth = isWidescreen ? 320.0 : 200.0;
      final nativeFont = Theme.of(context).textTheme.bodyLarge?.fontFamily;

      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              appText(context, english: 'No Results Found', arabic: 'لم يتم العثور على نتائج'),
              style: TextStyle(
                fontFamily: nativeFont,
                fontSize: 16,
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

    final isLarge = context.isTabletOrLarger;
    final maxExtent = isLarge ? 200.0 : 130.0;
    final footerCount = _isLoadingMore ? 1 : 0;

    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      gridDelegate: ResponsiveBreakpoints.animeGridDelegate(
        context,
        maxCrossAxisExtent: maxExtent,
        childAspectRatio: 2 / 3.2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: _items.length + footerCount,
      itemBuilder: (context, index) {
        if (index >= _items.length) {
          return const AnimePosterShimmer();
        }

        final item = _items[index];
        final providerId = _providerId ?? 'provider';
        final uniqueTag = 'search_${providerId}_${item.url}_$index';

        return MultimediaCard(
          key: ValueKey(_itemKey(item)),
          imageUrl: AppImageFallbacks.poster(item.posterUrl, label: item.title),
          title: item.title,
          heroTag: uniqueTag,
          onTap: () => DetailsRoute(
            $extra: DetailsRouteExtra(item: item),
          ).push<void>(context),
        );
      },
    );
  }
}
