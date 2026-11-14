import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:dio/dio.dart';

import '../../../../core/account/account_providers.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../../core/extensions/providers/anime_rift_provider.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import 'search_domain.dart';

part 'search_provider.g.dart';

enum SearchFilter { content, live }

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
  final String? error;

  ProviderSearchResult({
    required this.providerId,
    required this.providerName,
    required this.results,
    this.error,
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

// ---------------------------------------------------------------------------
// Background isolate helper — runs title filtering off the main thread.
// ---------------------------------------------------------------------------
class _FilterParams {
  final List<MultimediaItem> items;
  final List<String> queryParts;
  const _FilterParams(this.items, this.queryParts);
}

List<MultimediaItem> _filterItems(_FilterParams params) {
  return params.items.where((item) {
    final titleLower = item.title.toLowerCase();
    final titleParts = titleLower
        .split(' ')
        .where((s) => s.isNotEmpty)
        .toList();
    for (final qPart in params.queryParts) {
      bool foundPrefix = false;
      for (final tPart in titleParts) {
        if (tPart.startsWith(qPart)) {
          foundPrefix = true;
          break;
        }
      }
      if (!foundPrefix) return false;
    }
    return true;
  }).toList();
}

Stream<SearchAggregateState> searchAllProviders(
  Ref ref,
  String query,
  ExtensionManager manager, {
  required SearchFilter filter,
  required ProviderSearchFilters providerFilters,
  required bool Function() isCancelled,
}) async* {
  final allProviders = manager.getAllProviders();
  final providers = allProviders.where((p) {
    final isLiveOnly =
        p.supportedTypes.isNotEmpty &&
        p.supportedTypes.every((t) => t == ProviderType.livestream);
    return filter == SearchFilter.live ? isLiveOnly : !isLiveOnly;
  }).toList();
  debugPrint(
    '[SEARCH DBG] searchAllProviders called: queryLength=${query.runes.length}, providers=${providers.length}, cancelled=${isCancelled()}',
  );

  if (providers.isEmpty) {
    yield const SearchAggregateState(results: [], isLoading: false);
    return;
  }

  yield const SearchAggregateState(results: [], isLoading: true);

  final results = <ProviderSearchResult>[];
  final queryLower = query.toLowerCase();
  final queryParts = queryLower.split(' ').where((s) => s.isNotEmpty).toList();

  final controller = StreamController<SearchAggregateState>();

  // Semaphore sizing based on hardware
  int getSemaphoreSize() {
    int maxSlots = 8;
    try {
      final cores = io.Platform.numberOfProcessors;
      if (io.Platform.isMacOS || io.Platform.isWindows || io.Platform.isLinux) {
        // Keep provider fan-out bounded so large desktop searches don't saturate
        // CPU/network callbacks and starve Flutter's UI isolate.
        maxSlots = 16;
      } else {
        // Mobile: eval burst queue serializes HTTP callbacks, but CF bypass
        // WebView GPU init is still expensive — cap at 8 to avoid triggering
        // too many concurrent CF solves while the spawn semaphore queues them.
        maxSlots = cores.clamp(3, 6);
      }
    } catch (_) {}
    return maxSlots;
  }

  final maxSlots = getSemaphoreSize();
  int activeJobs = 0;

  // Livestream-only providers (large M3U playlists) are deprioritized to the
  // back of the queue. They still run and IPTV channel searches work; we just
  // let movie/series providers finish their burst first to reduce peak jank.
  final sortedProviders = List<AnimeWitcherProvider>.from(providers)
    ..sort((a, b) {
      final aLiveOnly =
          a.supportedTypes.isNotEmpty &&
          a.supportedTypes.every((t) => t == ProviderType.livestream);
      final bLiveOnly =
          b.supportedTypes.isNotEmpty &&
          b.supportedTypes.every((t) => t == ProviderType.livestream);
      if (aLiveOnly == bLiveOnly) return 0;
      return aLiveOnly ? 1 : -1;
    });
  final queue = List<AnimeWitcherProvider>.from(sortedProviders);
  final List<CancelToken> activeTokens = [];
  final List<AnimeWitcherProvider> activeProviders = [];
  bool isCompleted = false;

  Timer? throttleTimer;
  bool pendingEmit = false;
  // Track what was last emitted so we skip rebuilds when nothing new arrived.
  int lastEmittedResultCount = 0;

  void doEmit({bool force = false}) {
    if (controller.isClosed || isCancelled()) {
      return;
    }
    final stillLoading = queue.isNotEmpty || activeJobs > 0;
    // Skip the rebuild if no new results have arrived since the last emit
    // (e.g. a batch of providers all returned empty). Always emit on the
    // final event so isLoading flips to false.
    if (!force && stillLoading && results.length == lastEmittedResultCount) {
      pendingEmit = false;
      return;
    }
    lastEmittedResultCount = results.length;
    final totalItems = results.fold<int>(0, (sum, r) => sum + r.results.length);
    debugPrint(
      '[SEARCH DBG] doEmit — ${results.length} providers, $totalItems items, loading=$stillLoading',
    );
    controller.add(
      SearchAggregateState(
        results: List.from(results),
        isLoading: stillLoading,
      ),
    );
    pendingEmit = false;
  }

  void scheduleEmit({bool force = false}) {
    if (isCancelled() || controller.isClosed) return;

    if (force) {
      throttleTimer?.cancel();
      throttleTimer = null;
      doEmit(force: true);
      return;
    }

    pendingEmit = true;
    // Mobile gets a wider throttle window to reduce rebuild frequency
    // during high-concurrency search phases (70 providers).
    final throttleDuration = (io.Platform.isAndroid || io.Platform.isIOS)
        ? const Duration(milliseconds: 500)
        : const Duration(milliseconds: 150);
    throttleTimer ??= Timer(throttleDuration, () {
      throttleTimer = null;
      if (pendingEmit) doEmit();
    });
  }

  void processNext() {
    if (isCancelled()) {
      for (final t in activeTokens) {
        if (!t.isCancelled) t.cancel('Search cancelled');
      }
      activeTokens.clear();
      // Drop any IIFE evals still waiting in the JS queue for active providers.
      for (final p in activeProviders) {
        p.cancelInit();
      }
      activeProviders.clear();
      return;
    }

    // Fill up to max slots
    while (activeJobs < maxSlots && queue.isNotEmpty) {
      final provider = queue.removeAt(0);
      activeJobs++;
      final token = CancelToken();
      activeTokens.add(token);
      activeProviders.add(provider);

      Future(() async {
        if (isCancelled() || token.isCancelled) {
          debugPrint(
            '[SEARCH DBG] SKIP ${provider.packageName} — cancelled before start',
          );
          return;
        }

        try {
          debugPrint('[SEARCH DBG] START ${provider.packageName}');
          final rawResults = await provider.searchWithFilters(
            query,
            providerFilters,
            cancelToken: token,
          );
          debugPrint(
            '[SEARCH DBG] DONE ${provider.packageName} — rawResults=${rawResults.length}',
          );
          if (isCancelled() || token.isCancelled) {
            debugPrint(
              '[SEARCH DBG] CANCELLED after search ${provider.packageName}',
            );
            return;
          }

          final providerItems = rawResults
              .map(
                (item) => MultimediaItem(
                  title: item.title,
                  url: item.url,
                  posterUrl: item.posterUrl,
                  fullPosterUrl: item.fullPosterUrl,
                  bannerUrl: item.bannerUrl,
                  description: item.description,
                  contentType: item.contentType,
                  episodes: item.episodes,
                  provider: provider.packageName,
                ),
              )
              .toList();

          // For small result sets, skip the compute() isolate overhead
          // (spawn + serialize + deserialize costs more than the filter work).
          final filtered = providerItems.length < 30
              ? _filterItems(_FilterParams(providerItems, queryParts))
              : await compute(
                  _filterItems,
                  _FilterParams(providerItems, queryParts),
                );
          debugPrint(
            '[SEARCH DBG] FILTERED ${provider.packageName} — ${filtered.length}/${providerItems.length} items',
          );

          if (isCancelled() || token.isCancelled) {
            debugPrint(
              '[SEARCH DBG] CANCELLED after filter ${provider.packageName}',
            );
            return;
          }

          // Only add to state when there are actual results — empty entries
          // grow the list, force larger List.from() copies in doEmit, and
          // cause needless ListView rebuilds for no visual change.
          if (filtered.isNotEmpty) {
            results.add(
              ProviderSearchResult(
                providerId: provider.packageName,
                providerName: provider.name,
                results: filtered,
              ),
            );
            debugPrint(
              '[SEARCH DBG] ADDED ${provider.packageName} — total results sets=${results.length}',
            );
          }
        } catch (e) {
          debugPrint('[SEARCH DBG] ERROR ${provider.packageName}: $e');
          if (isCancelled() || token.isCancelled) {
            debugPrint(
              '[SEARCH DBG] CANCELLED during error ${provider.packageName}',
            );
            return;
          }
          if (e is DioException && e.type == DioExceptionType.cancel) return;
          // Don't add error entries with empty results — they add state size
          // with no user-visible benefit.
        } finally {
          activeJobs--;
          activeTokens.remove(token);
          activeProviders.remove(provider);

          final isLast = activeJobs == 0 && queue.isEmpty;
          debugPrint(
            '[SEARCH DBG] FINALLY ${provider.packageName} — activeJobs=$activeJobs, queueLeft=${queue.length}, isLast=$isLast, cancelled=${isCancelled()}, controllerClosed=${controller.isClosed}',
          );
          scheduleEmit(force: isLast);

          if (isLast && !isCompleted) {
            isCompleted = true;
            debugPrint(
              '[SEARCH DBG] ALL DONE — total result sets=${results.length}',
            );
            if (!controller.isClosed) {
              unawaited(
                Future.microtask(() {
                  if (!controller.isClosed) controller.close();
                }),
              );
            }
          } else if (!isCancelled()) {
            processNext();
          }
        }
      });
    }
  }

  processNext();

  yield* controller.stream;
}

@Riverpod(keepAlive: true)
class SearchQuery extends _$SearchQuery {
  @override
  String build() => '';

  void set(String query) => state = query;
}

@Riverpod(keepAlive: true)
class SearchFilterNotifier extends _$SearchFilterNotifier {
  @override
  SearchFilter build() => SearchFilter.content;

  void set(SearchFilter filter) => state = filter;
}

class SearchProviderFiltersNotifier extends Notifier<ProviderSearchFilters> {
  @override
  ProviderSearchFilters build() {
    final domain = ref.watch(searchDomainProvider);
    final provider = domain == SearchDomain.anime
        ? ref.watch(activeProviderProvider)
        : null;
    return ProviderSearchFilters(
      sort: provider is AnimeRiftProvider ? 'year_asc' : 'favorites',
    );
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

class PagedSearchNotifier extends Notifier<SearchAggregateState> {
  int _generation = 0;
  String _query = '';
  SearchDomain _domain = SearchDomain.anime;
  ProviderSearchFilters _filters = const ProviderSearchFilters();

  @override
  SearchAggregateState build() {
    ref.listen(searchQueryProvider, (previous, next) {
      _query = next;
      // A new search drops what was shown — the catalogue an empty search
      // browses, or the last search — so it is not on screen as if it were
      // the answer while the new one loads.
      _reload(clearExisting: previous?.trim() != next.trim());
    });
    ref.listen(searchProviderFiltersProvider, (_, next) {
      _filters = next;
      _reload();
    });
    ref.listen(searchDomainProvider, (_, next) {
      _domain = next;
      _reload(clearExisting: true);
    });
    // An account switch must immediately hide the previous account's items.
    // A failed replacement request must never reveal its cached results.
    ref.listen(
      accountDataRevisionProvider,
      (_, _) => _reload(clearExisting: true),
    );
    ref.listen(activeProviderProvider, (previous, next) {
      if (previous?.packageName == next?.packageName) return;
      if (_domain == SearchDomain.anime ||
          _domain == SearchDomain.characters ||
          _domain == SearchDomain.all) {
        _reload(clearExisting: true);
      }
    });
    _query = ref.read(searchQueryProvider);
    _domain = ref.read(searchDomainProvider);
    _filters = ref.read(searchProviderFiltersProvider);
    Future.microtask(_reload);
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
    SearchDomain domain,
  ) {
    final pageSize = provider.searchPageSize;
    final filters =
        domain == SearchDomain.anime &&
            _domain == SearchDomain.all &&
            provider is AnimeRiftProvider
        ? const ProviderSearchFilters(sort: 'year_asc')
        : _filters;
    return switch (domain) {
      SearchDomain.anime => provider.searchPage(
        _query,
        filters,
        offset: offset,
        limit: pageSize,
      ),
      SearchDomain.animation => provider.searchAnimationPage(
        _query,
        _filters,
        offset: offset,
        limit: pageSize,
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

  Future<void> _reload({bool clearExisting = false}) async {
    final generation = ++_generation;
    final requestDomain = _domain;
    state = clearExisting
        ? const SearchAggregateState(isLoading: true)
        : state.copyWith(
            isLoading: true,
            isLoadingMore: false,
            hasMore: false,
            nextOffset: 0,
            clearError: true,
          );
    final provider = _provider();
    if (provider == null) {
      if (generation == _generation) {
        state = const SearchAggregateState();
      }
      return;
    }

    try {
      if (requestDomain == SearchDomain.all) {
        final everything = await _loadEverything(provider);
        if (generation != _generation || requestDomain != _domain) return;
        state = everything;
        return;
      }

      if (requestDomain == SearchDomain.characters) {
        final page = await _loadCharacterPage(provider, 0);
        if (generation != _generation || requestDomain != _domain) return;
        state = SearchAggregateState(
          characters: page.items,
          isLoading: false,
          hasMore: page.hasMore,
          nextOffset: page.page + 1,
        );
        return;
      }

      final page = await _loadPage(provider, 0, requestDomain);
      if (generation != _generation || requestDomain != _domain) return;
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
      debugPrint('[SEARCH PAGE] initial load failed: $e');
      if (generation == _generation && requestDomain == _domain) {
        // Keep the last rendered cards on transient network failures. Show the
        // recoverable empty state only when there is nothing left to display.
        final hasCards =
            state.characters.isNotEmpty ||
            state.results.any((entry) => entry.results.isNotEmpty);
        state = state.copyWith(
          isLoading: false,
          isLoadingMore: false,
          hasMore: false,
          errorMessage: hasCards
              ? null
              : (e is AnimeRiftAccessUnavailable
                    ? e.toString()
                    : 'Unable to load search results.'),
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
        if (generation != _generation || requestDomain != _domain) return;
        final seen = <String>{};
        final merged = <Actor>[];
        for (final item in <Actor>[...state.characters, ...page.items]) {
          final id = item.id?.trim() ?? '';
          final key = id.isNotEmpty
              ? id
              : '${item.name.trim().toLowerCase()}|${item.image ?? ''}';
          if (seen.add(key)) merged.add(item);
        }
        state = SearchAggregateState(
          characters: merged,
          isLoading: false,
          isLoadingMore: false,
          hasMore: page.hasMore,
          nextOffset: page.page + 1,
        );
        return;
      }

      final page = await _loadPage(provider, state.nextOffset, requestDomain);
      if (generation != _generation || requestDomain != _domain) return;
      final current = state.results.isEmpty
          ? const <MultimediaItem>[]
          : state.results.first.results;
      final seen = <String>{};
      final merged = <MultimediaItem>[];
      for (final item in <MultimediaItem>[...current, ...page.items]) {
        final key = item.url.trim().isNotEmpty
            ? item.url.trim()
            : '${item.provider ?? ''}|${item.title.trim().toLowerCase()}|${item.year ?? ''}';
        if (seen.add(key)) merged.add(item);
      }
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
      debugPrint('[SEARCH PAGE] load more failed: $e');
      if (generation == _generation && requestDomain == _domain) {
        state = state.copyWith(isLoadingMore: false);
      }
    }
  }

  Future<void> retry() {
    _provider()?.prepareForNetworkRetry();
    return _reload();
  }
}

final searchPagedResultsProvider =
    NotifierProvider<PagedSearchNotifier, SearchAggregateState>(
      PagedSearchNotifier.new,
    );

@Riverpod(keepAlive: true)
Stream<SearchAggregateState> searchResults(Ref ref) {
  ref.watch(accountDataRevisionProvider);
  final query = ref.watch(searchQueryProvider);
  final filter = ref.watch(searchFilterProvider);
  final providerFilters = ref.watch(searchProviderFiltersProvider);
  final manager = ref.read(extensionManagerProvider.notifier);

  debugPrint(
    '[SEARCH DBG] searchResults PROVIDER BUILT — queryLength=${query.runes.length}',
  );

  var cancelled = false;
  ref.onDispose(() {
    debugPrint(
      '[SEARCH DBG] searchResults DISPOSED — queryLength=${query.runes.length}',
    );
    cancelled = true;
  });

  return searchAllProviders(
    ref,
    query,
    manager,
    filter: filter,
    providerFilters: providerFilters,
    isCancelled: () => cancelled,
  );
}

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
    ref.onDispose(() {
      _debounce?.cancel();
    });
    return const SearchSuggestionState();
  }

  void _restartForCatalogChange() {
    final query = state.query;
    clear();
    onQueryChanged(query);
  }

  void onQueryChanged(String query) {
    if (query == state.query) return;

    final generation = ++_generation;
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      _debounce?.cancel();
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

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
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
                  .search(query)
                  .catchError((Object _) => const <MultimediaItem>[])
            : Future.value(const <MultimediaItem>[]);
        final anime = await animeFuture;
        final animation = await animationFuture;
        final mangaItems = await mangaFuture;
        final characters = await charactersFuture;
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
      }
    });
  }

  void clear() {
    _generation++;
    _debounce?.cancel();
    state = const SearchSuggestionState();
  }
}
