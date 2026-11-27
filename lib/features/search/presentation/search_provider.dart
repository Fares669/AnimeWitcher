import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/account/account_providers.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import 'search_domain.dart';

part 'search_provider.g.dart';

/// Non-anime tabs use their own catalog, independently of the selected anime
/// provider and of extension registration order.
AnimeWitcherProvider? searchCatalogProvider(
  SearchDomain domain,
  Iterable<AnimeWitcherProvider> providers, {
  AnimeWitcherProvider? activeAnimeProvider,
}) {
  if (domain == SearchDomain.anime || domain == SearchDomain.all) return null;
  if (domain == SearchDomain.characters &&
      activeAnimeProvider?.supportsCharacters == true) {
    return activeAnimeProvider;
  }
  if (domain == SearchDomain.manga) {
    for (final provider in providers) {
      if (provider is AnimeWitcherNativeProvider) return provider;
    }
    for (final provider in providers) {
      if (provider.supportedTypes.contains(ProviderType.manga)) return provider;
    }
    return null;
  }
  // Animation and characters are exposed by the native catalog API.
  for (final provider in providers) {
    if (provider is AnimeWitcherNativeProvider) return provider;
  }
  return null;
}

/// Filter options for anime follow the chosen provider; other catalogs keep
/// their own provider regardless of the anime selection.
Future<ProviderSearchFilterOptions> searchFilterOptionsFor(
  SearchDomain domain,
  AnimeWitcherProvider? animeProvider,
  AnimeWitcherProvider? catalogProvider,
) async {
  if (!domain.capabilities.showFilter) {
    return const ProviderSearchFilterOptions();
  }
  if (domain == SearchDomain.anime) {
    return await animeProvider?.getSearchFilterOptions() ??
        const ProviderSearchFilterOptions();
  }
  if (domain == SearchDomain.manga) {
    return await catalogProvider?.getMangaSearchFilterOptions() ??
        const ProviderSearchFilterOptions();
  }
  if (domain == SearchDomain.animation && catalogProvider != null) {
    final options = await catalogProvider.getSearchFilterOptions();
    return ProviderSearchFilterOptions(
      statuses: options.statuses,
      types: options.types,
      ageRatings: options.ageRatings,
      years: options.years,
      seasons: options.seasons,
      genres: options.genres
          .where((genre) => genre != 'انميشن')
          .toList(growable: false),
    );
  }
  return const ProviderSearchFilterOptions();
}

bool searchFilterRequestIsStale(
  SearchDomain domain,
  String? initialAnimeProviderId,
  String? currentAnimeProviderId,
) =>
    domain == SearchDomain.anime &&
    initialAnimeProviderId != currentAnimeProviderId;

class ProviderSearchResult {
  final String providerId;
  final String providerName;
  final List<MultimediaItem> results;

  ProviderSearchResult({
    required this.providerId,
    required this.providerName,
    required this.results,
  });
}

class SearchAggregateState {
  final List<ProviderSearchResult> results;
  final List<Actor> characters;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final int nextOffset;
  final String? errorMessage;

  const SearchAggregateState({
    this.results = const [],
    this.characters = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.nextOffset = 0,
    this.errorMessage,
  });

  SearchAggregateState copyWith({
    List<ProviderSearchResult>? results,
    List<Actor>? characters,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    int? nextOffset,
    String? errorMessage,
    bool clearError = false,
  }) {
    return SearchAggregateState(
      results: results ?? this.results,
      characters: characters ?? this.characters,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      nextOffset: nextOffset ?? this.nextOffset,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

@Riverpod(keepAlive: true)
class SearchQuery extends _$SearchQuery {
  @override
  String build() => '';

  void set(String query) => state = query;
}

class SearchProviderFiltersNotifier extends Notifier<ProviderSearchFilters> {
  @override
  ProviderSearchFilters build() {
    ref.watch(searchDomainProvider);
    return const ProviderSearchFilters(sort: 'favorites');
  }

  void set(ProviderSearchFilters value) => state = value;
}

final searchProviderFiltersProvider =
    NotifierProvider<SearchProviderFiltersNotifier, ProviderSearchFilters>(
      SearchProviderFiltersNotifier.new,
    );

class SearchFocusRequestNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

final searchFocusRequestProvider =
    NotifierProvider<SearchFocusRequestNotifier, int>(
      SearchFocusRequestNotifier.new,
    );

class SearchClearRequestNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void request() => state++;
}

final searchClearRequestProvider =
    NotifierProvider<SearchClearRequestNotifier, int>(
      SearchClearRequestNotifier.new,
    );

// A published list remains an independent snapshot. The identity index only
// belongs to the latest list and is discarded on reload or at the last page.
class _SearchPageIndex<T> {
  List<T>? _rows;
  Set<String>? _keys;

  void reset() {
    _rows = null;
    _keys = null;
  }

  List<T> append(
    List<T> current,
    List<T> incoming,
    String Function(T) keyOf, {
    required bool hasMore,
  }) {
    final saved = identical(_rows, current) ? _keys : null;
    late final List<T> merged;
    late final Set<String> keys;
    if (saved == null) {
      // The initial page is rendered as received. On the first append, keep
      // its first occurrence of each key, exactly like later pages.
      keys = <String>{};
      merged = <T>[];
      void collect(List<T> items) {
        for (final item in items) {
          if (keys.add(keyOf(item))) merged.add(item);
        }
      }

      collect(current);
      collect(incoming);
    } else {
      final additions = <T>[];
      final addedKeys = <String>{};
      for (final item in incoming) {
        final key = keyOf(item);
        if (!saved.contains(key) && addedKeys.add(key)) additions.add(item);
      }
      // Keep the old list intact for readers holding a previous state.
      merged = additions.isEmpty ? current : <T>[...current, ...additions];
      keys = saved;
      if (hasMore) keys.addAll(addedKeys);
    }

    if (hasMore) {
      _rows = merged;
      _keys = keys;
    } else {
      reset();
    }
    return merged;
  }
}

String _mediaPageKey(MultimediaItem item) {
  final url = item.url.trim();
  return url.isNotEmpty
      ? url
      : '${item.provider ?? ''}|${item.title.trim().toLowerCase()}|${item.year ?? ''}';
}

String _characterPageKey(Actor item) {
  final id = item.id?.trim() ?? '';
  return id.isNotEmpty
      ? id
      : '${item.name.trim().toLowerCase()}|${item.image ?? ''}';
}

class PagedSearchNotifier extends Notifier<SearchAggregateState> {
  final _mediaIndex = _SearchPageIndex<MultimediaItem>();
  final _characterIndex = _SearchPageIndex<Actor>();
  int _generation = 0;
  String _query = '';
  SearchDomain _domain = SearchDomain.anime;
  ProviderSearchFilters _filters = const ProviderSearchFilters();
  Future<void>? _scheduledReload;
  CancelToken? _nativePage;

  @override
  SearchAggregateState build() {
    ref.onDispose(() {
      _generation++;
      _cancelNativePage();
      _scheduledReload = null;
      _mediaIndex.reset();
      _characterIndex.reset();
    });
    ref.listen(searchQueryProvider, (previous, next) {
      _query = next;
      // A new search drops what was shown — the catalogue an empty search
      // browses, or the last search — so it is not on screen as if it were
      // the answer while the new one loads.
      _scheduleReload(clearExisting: previous?.trim() != next.trim());
    });
    ref.listen(searchProviderFiltersProvider, (_, _) => _scheduleReload());
    ref.listen(searchDomainProvider, (_, next) {
      _domain = next;
      _scheduleReload(clearExisting: true);
    });
    // An account switch must immediately hide the previous account's items.
    // A failed replacement request must never reveal its cached results.
    ref.listen(
      accountDataRevisionProvider,
      (_, _) => _scheduleReload(clearExisting: true),
    );
    ref.listen(activeProviderProvider, (previous, next) {
      if (previous?.packageName == next?.packageName) return;
      if (_domain == SearchDomain.anime ||
          _domain == SearchDomain.characters ||
          _domain == SearchDomain.all) {
        _scheduleReload(clearExisting: true);
      }
    });
    _query = ref.read(searchQueryProvider);
    _domain = ref.read(searchDomainProvider);
    _scheduleReload(initial: true);
    return const SearchAggregateState(isLoading: true);
  }

  AnimeWitcherProvider? _provider([SearchDomain? domain]) {
    if ((domain ?? _domain) == SearchDomain.anime ||
        (domain ?? _domain) == SearchDomain.all) {
      return ref.read(activeProviderProvider);
    }
    return searchCatalogProvider(
      domain ?? _domain,
      ref.read(extensionManagerProvider.notifier).getAllProviders(),
      activeAnimeProvider: ref.read(activeProviderProvider),
    );
  }

  Future<ProviderMediaPage> _loadPage(
    AnimeWitcherProvider provider,
    int offset,
    SearchDomain domain, {
    CancelToken? cancelToken,
  }) {
    final pageSize = provider.searchPageSize;
    return switch (domain) {
      SearchDomain.anime => provider.searchPage(
        _query,
        _filters,
        offset: offset,
        limit: pageSize,
        cancelToken: cancelToken,
      ),
      SearchDomain.animation => provider.searchAnimationPage(
        _query,
        _filters,
        offset: offset,
        limit: pageSize,
        cancelToken: cancelToken,
      ),
      SearchDomain.manga => provider.searchMangaPage(
        _query,
        _filters,
        offset: offset,
        limit: pageSize,
      ),
      // Characters have a page type of their own, and "all" is assembled
      // from the others by _loadEverything.
      SearchDomain.characters ||
      SearchDomain.all => Future<ProviderMediaPage>.value(
        const ProviderMediaPage(
          items: <MultimediaItem>[],
          nextOffset: 0,
          hasMore: false,
        ),
      ),
    };
  }

  Future<ProviderMediaPage> _loadCommittedPage(
    AnimeWitcherProvider provider,
    int offset,
    SearchDomain domain,
  ) async {
    // The committed Manga filter path shares pending catalog requests only
    // without a token. Leave it, aggregate results and other providers alone.
    if (provider is! AnimeWitcherNativeProvider ||
        (domain != SearchDomain.anime && domain != SearchDomain.animation)) {
      return _loadPage(provider, offset, domain);
    }

    final token = CancelToken();
    _nativePage = token;
    try {
      return await _loadPage(provider, offset, domain, cancelToken: token);
    } finally {
      if (identical(_nativePage, token)) _nativePage = null;
    }
  }

  void _cancelNativePage() {
    final token = _nativePage;
    _nativePage = null;
    token?.cancel('Committed search superseded');
  }

  Future<ProviderCharacterPage> _loadCharacterPage(
    AnimeWitcherProvider provider,
    int page,
  ) {
    return provider.searchCharacterPage(_query.trim(), page: page);
  }

  /// The first page of each category at once, for [SearchDomain.all]: one
  /// result group per category that found something, named after it, and
  /// the characters beside them. A category that fails is left out rather
  /// than failing the rest; only when every one fails is it an error. There
  /// is no next page — each group links to its own category for more.
  Future<SearchAggregateState> _loadEverything(
    AnimeWitcherProvider provider,
  ) async {
    const media = <SearchDomain>[
      SearchDomain.anime,
      SearchDomain.animation,
      SearchDomain.manga,
    ];
    Future<ProviderMediaPage?> mediaPage(SearchDomain domain) {
      final catalog = domain == SearchDomain.anime
          ? provider
          : _provider(domain);
      if (catalog == null) return Future.value(null);
      return _loadPage(catalog, 0, domain).then<ProviderMediaPage?>(
        (page) => page,
        onError: (Object e) {
          debugPrint('[SEARCH ALL] ${domain.name} failed: $e');
          return null;
        },
      );
    }

    final charactersProvider = _provider(SearchDomain.characters);
    final characterPage = charactersProvider == null
        ? Future<ProviderCharacterPage?>.value(null)
        : _loadCharacterPage(
            charactersProvider,
            0,
          ).then<ProviderCharacterPage?>(
            (page) => page,
            onError: (Object e) {
              debugPrint('[SEARCH ALL] characters failed: $e');
              return null;
            },
          );
    final pages = await Future.wait(media.map(mediaPage));
    final characters = await characterPage;

    if (pages.every((page) => page == null) && characters == null) {
      throw StateError('Every search category failed.');
    }
    return SearchAggregateState(
      results: <ProviderSearchResult>[
        for (var i = 0; i < media.length; i++)
          if (pages[i]?.items.isNotEmpty ?? false)
            ProviderSearchResult(
              providerId: media[i].name,
              providerName: media[i].name,
              results: pages[i]!.items,
            ),
      ],
      characters: characters?.items ?? const <Actor>[],
      isLoading: false,
    );
  }

  Future<void> _scheduleReload({
    bool clearExisting = false,
    bool initial = false,
  }) {
    const cleared = SearchAggregateState(isLoading: true);
    final scheduled = _scheduledReload;
    if (scheduled != null) {
      if (clearExisting) state = cleared;
      return scheduled;
    }

    // The filter sheet may change the category, reset its filters and apply
    // the selected ones in the same turn. Invalidate old results immediately
    // but start the first page only after those inputs have settled.
    final generation = ++_generation;
    _cancelNativePage();
    _mediaIndex.reset();
    _characterIndex.reset();
    final reload = Future<void>.microtask(() async {
      if (!ref.mounted || generation != _generation) return;
      // Reading also flushes the domain-dependent defaults when no widget has
      // read them yet. Keep the scheduled reload visible to that listener.
      _filters = ref.read(searchProviderFiltersProvider);
      _scheduledReload = null;
      await _loadFirstPage(generation);
    });
    _scheduledReload = reload;
    if (!initial) {
      state = clearExisting
          ? cleared
          : state.copyWith(
              isLoading: true,
              isLoadingMore: false,
              hasMore: false,
              nextOffset: 0,
              clearError: true,
            );
    }
    return reload;
  }

  bool _isCurrent(int generation, SearchDomain domain) =>
      ref.mounted && generation == _generation && domain == _domain;

  Future<void> _loadFirstPage(int generation) async {
    final requestDomain = _domain;
    final provider = _provider();
    if (provider == null) {
      if (_isCurrent(generation, requestDomain)) {
        state = const SearchAggregateState();
      }
      return;
    }

    try {
      if (requestDomain == SearchDomain.all) {
        final everything = await _loadEverything(provider);
        if (!_isCurrent(generation, requestDomain)) return;
        state = everything;
        return;
      }

      if (requestDomain == SearchDomain.characters) {
        final page = await _loadCharacterPage(provider, 0);
        if (!_isCurrent(generation, requestDomain)) return;
        state = SearchAggregateState(
          characters: page.items,
          isLoading: false,
          hasMore: page.hasMore,
          nextOffset: page.page + 1,
        );
        return;
      }

      final page = await _loadCommittedPage(provider, 0, requestDomain);
      if (!_isCurrent(generation, requestDomain)) return;
      state = SearchAggregateState(
        results: page.items.isEmpty
            ? const <ProviderSearchResult>[]
            : <ProviderSearchResult>[
                ProviderSearchResult(
                  providerId: provider.packageName,
                  providerName: provider.name,
                  results: page.items,
                ),
              ],
        isLoading: false,
        hasMore: page.hasMore,
        nextOffset: page.nextOffset,
      );
    } catch (e) {
      if (_isCurrent(generation, requestDomain)) {
        debugPrint('[SEARCH PAGE] initial load failed: $e');
        // Keep the last rendered cards on transient network failures. Show the
        // recoverable empty state only when there is nothing left to display.
        final hasCards =
            state.characters.isNotEmpty ||
            state.results.any((entry) => entry.results.isNotEmpty);
        state = state.copyWith(
          isLoading: false,
          isLoadingMore: false,
          hasMore: false,
          errorMessage: hasCards ? null : 'Unable to load search results.',
          clearError: hasCards,
        );
      }
    }
  }

  Future<void> loadMore() async {
    if (state.isLoading || state.isLoadingMore || !state.hasMore) return;
    final provider = _provider();
    if (provider == null) return;
    final generation = _generation;
    final requestDomain = _domain;
    state = state.copyWith(isLoadingMore: true);

    try {
      if (requestDomain == SearchDomain.characters) {
        final page = await _loadCharacterPage(provider, state.nextOffset);
        if (!_isCurrent(generation, requestDomain)) return;
        final merged = _characterIndex.append(
          state.characters,
          page.items,
          _characterPageKey,
          hasMore: page.hasMore,
        );
        state = SearchAggregateState(
          characters: merged,
          isLoading: false,
          isLoadingMore: false,
          hasMore: page.hasMore,
          nextOffset: page.page + 1,
        );
        return;
      }

      final page = await _loadCommittedPage(
        provider,
        state.nextOffset,
        requestDomain,
      );
      if (!_isCurrent(generation, requestDomain)) return;
      final current = state.results.isEmpty
          ? const <MultimediaItem>[]
          : state.results.first.results;
      final merged = _mediaIndex.append(
        current,
        page.items,
        _mediaPageKey,
        hasMore: page.hasMore,
      );
      state = SearchAggregateState(
        results: merged.isEmpty
            ? const <ProviderSearchResult>[]
            : <ProviderSearchResult>[
                ProviderSearchResult(
                  providerId: provider.packageName,
                  providerName: provider.name,
                  results: merged,
                ),
              ],
        isLoading: false,
        isLoadingMore: false,
        hasMore: page.hasMore,
        nextOffset: page.nextOffset,
      );
    } catch (e) {
      if (_isCurrent(generation, requestDomain)) {
        debugPrint('[SEARCH PAGE] load more failed: $e');
        state = state.copyWith(isLoadingMore: false);
      }
    }
  }

  Future<void> retry() {
    _provider()?.prepareForNetworkRetry();
    return _scheduleReload();
  }
}

final searchPagedResultsProvider =
    NotifierProvider<PagedSearchNotifier, SearchAggregateState>(
      PagedSearchNotifier.new,
    );

class SearchSuggestionState {
  final List<String> suggestions;

  /// The results the titles came from, for the results shown while typing:
  /// the category searched, or anime when every category is.
  final List<MultimediaItem> items;

  /// Searching every category: what the others found.
  final List<MultimediaItem> animation;
  final List<MultimediaItem> manga;
  final List<Actor> characters;
  final bool isLoading;
  final String query;

  const SearchSuggestionState({
    this.suggestions = const [],
    this.items = const [],
    this.animation = const [],
    this.manga = const [],
    this.characters = const [],
    this.isLoading = false,
    this.query = '',
  });

  bool get hasResults =>
      items.isNotEmpty ||
      animation.isNotEmpty ||
      manga.isNotEmpty ||
      characters.isNotEmpty;

  SearchSuggestionState copyWith({
    List<String>? suggestions,
    List<MultimediaItem>? items,
    List<MultimediaItem>? animation,
    List<MultimediaItem>? manga,
    List<Actor>? characters,
    bool? isLoading,
    String? query,
  }) {
    return SearchSuggestionState(
      suggestions: suggestions ?? this.suggestions,
      items: items ?? this.items,
      animation: animation ?? this.animation,
      manga: manga ?? this.manga,
      characters: characters ?? this.characters,
      isLoading: isLoading ?? this.isLoading,
      query: query ?? this.query,
    );
  }
}

@riverpod
class SearchSuggestionController extends _$SearchSuggestionController {
  Timer? _debounce;
  CancelToken? _inFlight;
  int _generation = 0;

  @override
  SearchSuggestionState build() {
    ref.listen(accountDataRevisionProvider, (_, _) {
      // Invalidate the in-flight generation and purge the previous account's
      // instant suggestions before requesting the current account's catalog.
      _restartForCatalogChange();
    });
    ref.listen(activeProviderProvider, (previous, next) {
      if (previous?.packageName == next?.packageName) return;
      final domain = ref.read(searchDomainProvider);
      if (domain != SearchDomain.anime &&
          domain != SearchDomain.characters &&
          domain != SearchDomain.all) {
        return;
      }
      _restartForCatalogChange();
    });
    ref.listen(searchDomainProvider, (_, _) => _restartForCatalogChange());
    ref.onDispose(_cancelPendingWork);
    return const SearchSuggestionState();
  }

  void _cancelPendingWork() {
    _debounce?.cancel();
    _debounce = null;
    final inFlight = _inFlight;
    _inFlight = null;
    inFlight?.cancel();
  }

  void _restartForCatalogChange() {
    final query = state.query;
    clear();
    onQueryChanged(query);
  }

  void onQueryChanged(String query) {
    if (query == state.query) return;

    final generation = ++_generation;
    _cancelPendingWork();
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      state = state.copyWith(
        query: query,
        suggestions: const [],
        items: const [],
        animation: const [],
        manga: const [],
        characters: const [],
        isLoading: false,
      );
      return;
    }

    state = SearchSuggestionState(query: query, isLoading: true);

    if (!ref.mounted || generation != _generation) return;
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      _debounce = null;
      // Only instant suggestions share this token; a submitted result is
      // owned separately by PagedSearchNotifier.
      final token = CancelToken();
      _inFlight = token;
      try {
        final manager = ref.read(extensionManagerProvider.notifier);
        final providers = manager.getAllProviders();
        final domain = ref.read(searchDomainProvider);
        final animationProvider = searchCatalogProvider(
          SearchDomain.animation,
          providers,
        );
        final mangaProvider = searchCatalogProvider(
          SearchDomain.manga,
          providers,
        );
        final charactersProvider = searchCatalogProvider(
          SearchDomain.characters,
          providers,
          activeAnimeProvider: ref.read(activeProviderProvider),
        );
        final animeProvider = ref.read(activeProviderProvider);
        const none = ProviderSearchFilters();
        Future<List<MultimediaItem>> quiet(
          Future<ProviderMediaPage> Function() request,
        ) => request()
            .then((page) => page.items)
            .catchError((Object _) => const <MultimediaItem>[]);
        // Each category its own catalogue; "all" asks them all at once, as
        // the full search does, and a category that fails is left out.
        final everything = domain == SearchDomain.all;
        final animationFuture =
            animationProvider != null &&
                (everything || domain == SearchDomain.animation)
            ? quiet(
                () => animationProvider.searchAnimationPage(
                  query,
                  none,
                  offset: 0,
                  limit: 20,
                  cancelToken: token,
                ),
              )
            : Future.value(const <MultimediaItem>[]);
        final mangaFuture =
            mangaProvider != null &&
                (everything || domain == SearchDomain.manga)
            ? quiet(
                () => mangaProvider.searchMangaPage(
                  query,
                  none,
                  offset: 0,
                  limit: 20,
                  cancelToken: token,
                ),
              )
            : Future.value(const <MultimediaItem>[]);
        final charactersFuture =
            (everything || domain == SearchDomain.characters) &&
                charactersProvider?.supportsCharacters == true
            ? charactersProvider!
                  .searchCharacterPage(query)
                  .then((page) => page.items)
                  .catchError((Object _) => const <Actor>[])
            : Future.value(const <Actor>[]);
        final animeFuture =
            animeProvider != null &&
                (everything || domain == SearchDomain.anime)
            ? animeProvider
                  .search(query, cancelToken: token)
                  .catchError((Object _) => const <MultimediaItem>[])
            : Future.value(const <MultimediaItem>[]);
        final anime = await animeFuture;
        final animation = await animationFuture;
        final mangaItems = await mangaFuture;
        final characters = await charactersFuture;
        // A committed search or newer query may have invalidated this reply.
        // Do not walk either suggestion projection for an abandoned result.
        if (!ref.mounted || generation != _generation || state.query != query) {
          return;
        }
        final results = switch (domain) {
          SearchDomain.animation => animation,
          SearchDomain.manga => mangaItems,
          _ => anime,
        };
        final suggestions = results
            .map((item) => item.title.trim())
            .where((title) => title.isNotEmpty)
            .toSet()
            .take(10)
            .toList(growable: false);
        final seen = <String>{};
        final items = results
            .where((item) => item.title.trim().isNotEmpty && seen.add(item.url))
            .take(30)
            .toList(growable: false);
        if (ref.mounted && generation == _generation && state.query == query) {
          state = state.copyWith(
            suggestions: suggestions,
            items: items,
            animation: everything ? animation : const [],
            manga: everything ? mangaItems : const [],
            characters: characters.take(12).toList(growable: false),
            isLoading: false,
          );
        }
      } catch (_) {
        if (ref.mounted && generation == _generation && state.query == query) {
          state = state.copyWith(
            suggestions: const [],
            items: const [],
            animation: const [],
            manga: const [],
            characters: const [],
            isLoading: false,
          );
        }
      } finally {
        if (identical(_inFlight, token)) _inFlight = null;
      }
    });
  }

  void clear() {
    _generation++;
    _cancelPendingWork();
    state = const SearchSuggestionState();
  }
}
