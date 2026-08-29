import 'package:dio/dio.dart';
import '../domain/entity/multimedia_item.dart';

enum ProviderType { movie, series, anime, livestream, other }

class ProviderSearchFilterOptions {
  final List<String> statuses;
  final List<String> types;
  final List<String> ageRatings;
  final List<String> years;
  final List<String> seasons;
  final List<String> genres;

  const ProviderSearchFilterOptions({
    this.statuses = const <String>[],
    this.types = const <String>[],
    this.ageRatings = const <String>[],
    this.years = const <String>[],
    this.seasons = const <String>[],
    this.genres = const <String>[],
  });

  bool get isEmpty =>
      statuses.isEmpty &&
      types.isEmpty &&
      ageRatings.isEmpty &&
      years.isEmpty &&
      seasons.isEmpty &&
      genres.isEmpty;

  factory ProviderSearchFilterOptions.fromJson(Map<String, dynamic> json) {
    List<String> read(String key) {
      final value = json[key];
      if (value is! List) return const <String>[];
      return value
          .map((entry) => entry.toString().trim())
          .where((entry) => entry.isNotEmpty)
          .toSet()
          .toList(growable: false);
    }

    return ProviderSearchFilterOptions(
      statuses: read('statuses'),
      types: read('types'),
      ageRatings: read('ageRatings'),
      years: read('years'),
      seasons: read('seasons'),
      genres: read('genres'),
    );
  }
}

class ProviderSearchFilters {
  final Set<String> statuses;
  final Set<String> types;
  final Set<String> ageRatings;
  final Set<String> years;
  final Set<String> seasons;
  final Set<String> genres;
  final String sort;

  const ProviderSearchFilters({
    this.statuses = const <String>{},
    this.types = const <String>{},
    this.ageRatings = const <String>{},
    this.years = const <String>{},
    this.seasons = const <String>{},
    this.genres = const <String>{},
    this.sort = '',
  });

  bool get isEmpty => count == 0;
  bool get isNotEmpty => !isEmpty;

  int get count =>
      statuses.length +
      types.length +
      ageRatings.length +
      years.length +
      seasons.length +
      genres.length;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'statuses': statuses.toList(growable: false),
      'types': types.toList(growable: false),
      'ageRatings': ageRatings.toList(growable: false),
      'years': years.toList(growable: false),
      'seasons': seasons.toList(growable: false),
      'genres': genres.toList(growable: false),
      'sort': sort,
    };
  }

  ProviderSearchFilters copyWith({
    Set<String>? statuses,
    Set<String>? types,
    Set<String>? ageRatings,
    Set<String>? years,
    Set<String>? seasons,
    Set<String>? genres,
    String? sort,
  }) {
    return ProviderSearchFilters(
      statuses: statuses ?? this.statuses,
      types: types ?? this.types,
      ageRatings: ageRatings ?? this.ageRatings,
      years: years ?? this.years,
      seasons: seasons ?? this.seasons,
      genres: genres ?? this.genres,
      sort: sort ?? this.sort,
    );
  }
}

class ProviderMediaPage {
  final List<MultimediaItem> items;
  final int nextOffset;
  final bool hasMore;

  const ProviderMediaPage({
    required this.items,
    required this.nextOffset,
    required this.hasMore,
  });
}

class ProviderNewsPage {
  final List<NewsItem> items;
  final int nextOffset;
  final bool hasMore;

  const ProviderNewsPage({
    required this.items,
    required this.nextOffset,
    required this.hasMore,
  });
}

abstract class AnimeWitcherProvider {
  /// Unique provider package name.
  String get packageName;

  /// Display Name
  String get name;
  String get mainUrl;
  String get version;
  List<String> get languages;
  Set<ProviderType> get supportedTypes;
  bool get hasSearch => true;
  bool get isDebug => packageName.endsWith('.debug');

  /// Preferred provider-controlled batch sizes for paginated content.
  /// Providers can override these pagination sizes. The default remains 30.
  int get viewAllPageSize => 30;
  int get searchPageSize => 30;

  /// Cancel any pending JS eval for this provider so the queue isn't blocked
  /// by a stale IIFE load after the triggering search was abandoned.
  /// The provider resets itself so the next search retries cleanly.
  void cancelInit() {}

  // Key methods providers must implement
  Future<List<MultimediaItem>> search(String query, {CancelToken? cancelToken});

  /// Optional provider-defined search filter values.
  Future<ProviderSearchFilterOptions> getSearchFilterOptions() async {
    return const ProviderSearchFilterOptions();
  }

  /// Filtered search falls back to normal text search for older providers.
  Future<List<MultimediaItem>> searchWithFilters(
    String query,
    ProviderSearchFilters filters, {
    CancelToken? cancelToken,
  }) {
    return search(query, cancelToken: cancelToken);
  }

  /// Loads one search page. Older providers remain compatible through
  /// a bounded slice of their existing search result.
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit.clamp(1, 100).toInt();
    final all = await searchWithFilters(
      query,
      filters,
      cancelToken: cancelToken,
    );
    if (safeOffset >= all.length) {
      return ProviderMediaPage(
        items: const <MultimediaItem>[],
        nextOffset: safeOffset,
        hasMore: false,
      );
    }
    final end = (safeOffset + safeLimit).clamp(0, all.length).toInt();
    return ProviderMediaPage(
      items: all.sublist(safeOffset, end),
      nextOffset: end,
      hasMore: end < all.length,
    );
  }

  // Returns categorized content (Section Name -> Items)
  Future<Map<String, List<MultimediaItem>>> getHome();

  /// Loads the compact news feed shown on the provider home page.
  ///
  /// Older providers can leave the default empty implementation in place;
  /// this keeps news optional and prevents it from being mixed into anime
  /// sections.
  Future<ProviderNewsPage> getHomeNewsPage({
    int offset = 0,
    int limit = 10,
  }) async {
    return const ProviderNewsPage(
      items: <NewsItem>[],
      nextOffset: 0,
      hasMore: false,
    );
  }

  /// Loads the full provider news list.
  Future<ProviderNewsPage> getNewsPage({int offset = 0, int limit = 20}) {
    return getHomeNewsPage(offset: offset, limit: limit);
  }

  /// Loads the complete content for one provider home section.
  ///
  /// Providers that do not support lazy sections automatically fall
  /// back to their existing [getHome] result.
  Future<List<MultimediaItem>> getHomeSection(String sectionName) async {
    final home = await getHome();
    return home[sectionName] ?? const <MultimediaItem>[];
  }

  /// Loads one provider Home section page.
  Future<ProviderMediaPage> getHomeSectionPage(
    String sectionName, {
    int offset = 0,
    int limit = 30,
  }) async {
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit.clamp(1, 100).toInt();
    final all = await getHomeSection(sectionName);
    if (safeOffset >= all.length) {
      return ProviderMediaPage(
        items: const <MultimediaItem>[],
        nextOffset: safeOffset,
        hasMore: false,
      );
    }
    final end = (safeOffset + safeLimit).clamp(0, all.length).toInt();
    return ProviderMediaPage(
      items: all.sublist(safeOffset, end),
      nextOffset: end,
      hasMore: end < all.length,
    );
  }

  Future<MultimediaItem> getDetails(String url);

  /// Drops in-memory detail/episode caches for [url] so the next fetch hits
  /// the server. Used by pull-to-refresh on the anime details page.
  void invalidateDetailCaches(String url) {}

  /// Drops stale HTTP sockets and failed catalog TTL so Retry after reconnect
  /// issues a real request instead of reusing the offline failure.
  void prepareForNetworkRetry() {}

  /// Whether this provider exposes optional detail sections through separate
  /// requests. Controllers can then render every section as soon as it arrives.
  bool get supportsIndependentDetailSections => false;

  /// Loads cast independently from the main metadata request.
  Future<List<Actor>> getCast(String url) async {
    final details = await getDetails(url);
    return details.cast ?? const <Actor>[];
  }

  /// Loads trailers independently from the main metadata request.
  Future<List<Trailer>> getTrailers(String url) async {
    final details = await getDetails(url);
    return details.trailers ?? const <Trailer>[];
  }

  /// Loads franchise-related titles independently.
  Future<List<MultimediaItem>> getRelated(String url) async {
    final details = await getDetails(url);
    return details.related ?? const <MultimediaItem>[];
  }

  /// Related titles plus whether a المزيد tile should open the full list.
  ///
  /// [includeAll] resolves every `related_anime_ids` entry; the details tab
  /// preview only hydrates the first 10 Firestore IN values.
  Future<RelatedAnimePage> getRelatedPage(
    String url, {
    bool includeAll = false,
  }) async {
    return RelatedAnimePage(items: await getRelated(url));
  }

  /// Loads similar recommendations independently.
  Future<List<MultimediaItem>> getRecommendations(String url) async {
    final details = await getDetails(url);
    return details.recommendations ?? const <MultimediaItem>[];
  }

  /// Loads the next-airing entry independently from the main details request.
  ///
  /// Providers should return null until episode, time, and season are all known.
  Future<NextAiring?> getNextAiring(String url) async {
    final details = await getDetails(url);
    return details.nextAiring;
  }

  /// Loads episodes independently from the metadata/details request.
  ///
  /// Older providers remain compatible because the default implementation
  /// falls back to [getDetails] and extracts its embedded episodes.
  Future<List<Episode>> getEpisodes(String url) async {
    final details = await getDetails(url);
    return details.episodes ?? const <Episode>[];
  }

  /// Loads optional episode artwork and season/episode numbering separately.
  ///
  /// This must never be required for rendering the initial episode list.
  Future<List<Episode>> getEpisodeMetadata(String url) async {
    return const <Episode>[];
  }

  /// Lists sources that can be presented to the user before expensive
  /// extraction. Providers with no deferred extraction can keep the default.
  Future<List<StreamResult>> loadStreamSources(String url) {
    return loadStreams(url);
  }

  /// True when [url] represents a user-selected source token that must bypass
  /// automatic quality/source preference logic.
  bool isExplicitStreamSelection(String url) => false;

  // Resolves a playable stream URL. Deferred providers may accept one of the
  // opaque URLs returned by [loadStreamSources].
  Future<List<StreamResult>> loadStreams(String url);
}
