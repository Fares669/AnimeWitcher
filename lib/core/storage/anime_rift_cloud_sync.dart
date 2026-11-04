import '../domain/entity/multimedia_item.dart';
import '../extensions/providers/anime_rift_api_client.dart';
import 'library_category.dart';
import 'provider_local_history.dart';
import 'provider_local_library.dart';
import 'anime_rift_account_scope.dart';
import 'storage_service.dart';

/// The response body is intentionally opaque until authenticated examples
/// establish Rift's list and episode row schemas.
abstract class AnimeRiftCloudAccountReader {
  Future<bool> restoreAccountSession();

  Future<Map<String, dynamic>> fetchMyListOverview();

  Future<Map<String, dynamic>> fetchFavoriteAnime();

  Future<Map<String, dynamic>> fetchMyList(String category);

  Future<Map<String, dynamic>> fetchWatchHistoryLatest();

  Future<Map<String, dynamic>> fetchWatchHistoryFull();
}

/// Adapter for the authenticated, read-only endpoints of the real API client.
class AnimeRiftCloudApiReader implements AnimeRiftCloudAccountReader {
  AnimeRiftCloudApiReader(this.api);

  final AnimeRiftApiClient api;

  @override
  Future<bool> restoreAccountSession() => api.restoreAccountSession();

  @override
  Future<Map<String, dynamic>> fetchMyListOverview() =>
      api.fetchMyListOverview();

  @override
  Future<Map<String, dynamic>> fetchFavoriteAnime() => api.fetchFavoriteAnime();

  @override
  Future<Map<String, dynamic>> fetchMyList(String category) =>
      api.fetchMyList(category);

  @override
  Future<Map<String, dynamic>> fetchWatchHistoryLatest() =>
      api.fetchWatchHistoryLatest();

  @override
  Future<Map<String, dynamic>> fetchWatchHistoryFull() =>
      api.fetchWatchHistoryFull();
}

enum AnimeRiftCloudResponseShape {
  /// The `items` field was a list; this does not verify its row schema.
  itemsList,

  /// The `items` field was a map; this does not verify its row schema.
  itemsMap,

  /// The server responded, but the `items` shape was not recognized.
  unrecognized,

  /// A transient service/network error prevented checking this resource.
  unavailable,
}

class AnimeRiftCloudResourceInspection {
  const AnimeRiftCloudResourceInspection(this.shape, {this.returnedListLength});

  final AnimeRiftCloudResponseShape shape;

  /// Number of rows in the returned page only, never a cloud total.
  /// It does not indicate that any row is safe to import into local storage.
  final int? returnedListLength;
}

/// A transient inspection of Rift's authenticated cloud account.
///
/// All data access fails closed after an account switch. No cloud rows or
/// credentials are persisted, and no local or remote library writes occur.
class AnimeRiftCloudInspection {
  AnimeRiftCloudInspection._(
    this._accountHash,
    Map<String, int> overviewCounts,
    Map<String, AnimeRiftCloudResourceInspection> resources,
  ) : _overviewCounts = Map<String, int>.unmodifiable(overviewCounts),
      _resources = Map<String, AnimeRiftCloudResourceInspection>.unmodifiable(
        resources,
      );

  final String _accountHash;
  final Map<String, int> _overviewCounts;
  final Map<String, AnimeRiftCloudResourceInspection> _resources;

  bool get belongsToCurrentAccount =>
      AnimeRiftLocalAccountScope.accountHash == _accountHash;

  Map<String, int> get overviewCounts {
    _requireCurrentAccount();
    return _overviewCounts;
  }

  Map<String, AnimeRiftCloudResourceInspection> get resources {
    _requireCurrentAccount();
    return _resources;
  }

  void _requireCurrentAccount() {
    if (!belongsToCurrentAccount) {
      throw const AnimeRiftAuthenticationRequired();
    }
  }
}

/// Accepted cloud rows copied into the currently linked Rift account's local
/// library. Unknown rows are counted as skipped, never fabricated as anime.
class AnimeRiftCloudImportResult {
  const AnimeRiftCloudImportResult({
    required this.favorites,
    required this.categories,
    required this.history,
    required this.skipped,
  });

  final int favorites;
  final int categories;
  final int history;
  final int skipped;
}

/// Inspects remote counts and imports verified account lists additively.
/// The server's anime/episode row structure is not fully documented, so
/// unknown rows are skipped; existing local data is never removed.
class AnimeRiftCloudSync {
  AnimeRiftCloudSync(this._reader);

  final AnimeRiftCloudAccountReader _reader;

  static const listCategories = <String>[
    'favorite',
    'currently',
    'want_to',
    'later',
    'dropped',
  ];

  static const _categoryForList = <String, LibraryCategory>{
    'currently': LibraryCategory.watching,
    'want_to': LibraryCategory.planToWatch,
    'later': LibraryCategory.continueLater,
    'dropped': LibraryCategory.notInterested,
  };

  /// Import authenticated lists into the matching Rift account's actual
  /// library and watch history. Existing local entries are preserved; an
  /// unavailable or unrecognized response cannot erase the user's data.
  Future<AnimeRiftCloudImportResult> importToLocal({
    required StorageService storage,
    Future<MultimediaItem?> Function(String catalogUrl)? hydrate,
  }) async {
    final previous = AnimeRiftLocalAccountScope.accountHash;
    final linked = await _reader.restoreAccountSession();
    final account = AnimeRiftLocalAccountScope.accountHash;
    if (!linked ||
        account == null ||
        (previous != null && previous != account)) {
      throw const AnimeRiftAuthenticationRequired();
    }
    // Use the linked account namespace even on the first launch after login.
    final library = ProviderLocalLibrary(storage, animeRiftProviderId);
    final history = ProviderLocalHistory(storage, animeRiftProviderId);

    // Fetch before writing, so a failed request never looks like an empty
    // remote library and a changed session cannot import into another user.
    final remoteFavorites = _cloudRows(await _reader.fetchFavoriteAnime());
    _requireAccount(account);
    final remoteLists = <LibraryCategory, List<Object?>>{};
    for (final entry in _categoryForList.entries) {
      remoteLists[entry.value] = _cloudRows(
        await _reader.fetchMyList(entry.key),
      );
      _requireAccount(account);
    }
    final remoteHistory = _cloudRows(await _readWatchHistory());
    _requireAccount(account);

    final hydrated = <String, MultimediaItem?>{};
    var skipped = 0;
    Future<MultimediaItem?> parse(Object? row) async {
      final item = await _cloudAnime(row, hydrate, hydrated);
      _requireAccount(account);
      if (item == null) skipped++;
      return item;
    }

    final favorites = <MultimediaItem>[];
    for (final row in remoteFavorites) {
      final item = await parse(row);
      if (item != null) favorites.add(item);
    }
    final categories = <LibraryCategory, List<MultimediaItem>>{};
    for (final entry in remoteLists.entries) {
      final mapped = <MultimediaItem>[];
      for (final row in entry.value) {
        final item = await parse(row);
        if (item != null) mapped.add(item);
      }
      categories[entry.key] = mapped;
    }
    final watched = <MultimediaItem>[];
    for (final row in remoteHistory) {
      final item = await parse(row);
      if (item != null) watched.add(item);
    }

    _requireAccount(account);
    for (final item in favorites) {
      _requireAccount(account);
      await library.setFavorite(item, true);
    }
    for (final entry in categories.entries) {
      for (final item in entry.value) {
        _requireAccount(account);
        // Preserve the user's newer local changes when the remote state is
        // older or the backend does not expose a comparable timestamp.
        if (library.category(item.url) == null) {
          await library.setCategory(item, entry.key);
        }
      }
    }
    final knownHistory = history
        .history()
        .map((entry) => entry.item.url)
        .toSet();
    for (final item in watched) {
      _requireAccount(account);
      if (knownHistory.add(item.url)) await history.recordOpened(item);
    }
    _requireAccount(account);
    return AnimeRiftCloudImportResult(
      favorites: favorites.length,
      categories: categories.values.fold<int>(0, (n, rows) => n + rows.length),
      history: watched.length,
      skipped: skipped,
    );
  }

  Future<Map<String, dynamic>> _readWatchHistory() async {
    try {
      return await _reader.fetchWatchHistoryFull();
    } on AnimeRiftAuthenticationRequired {
      rethrow;
    } on AnimeRiftAccessUnavailable {
      return _reader.fetchWatchHistoryLatest();
    }
  }

  List<Object?> _cloudRows(Map<String, dynamic> response) {
    final items = response['items'];
    if (items is List) return List<Object?>.from(items);
    if (items is Map) {
      for (final field in const ['items', 'data', 'results']) {
        final rows = items[field];
        if (rows is List) return List<Object?>.from(rows);
      }
    }
    throw const AnimeRiftAccessUnavailable();
  }

  Future<MultimediaItem?> _cloudAnime(
    Object? value,
    Future<MultimediaItem?> Function(String)? hydrate,
    Map<String, MultimediaItem?> cache,
  ) async {
    if (value is! Map) return null;
    final embedded = value['anime'] is Map
        ? value['anime'] as Map
        : value['_anime'] is Map
        ? value['_anime'] as Map
        : null;
    final row = embedded ?? value;
    // A list-membership row can have its own `_id`. Its `anime_id` or
    // embedded anime identifies the actual catalog item.
    final id = embedded != null
        ? row['_id'] ?? row['anime_id'] ?? row['animeId']
        : value['anime_id'] ??
              value['animeId'] ??
              value['_anime'] ??
              value['anime'] ??
              value['_id'];
    if (id is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      return null;
    }
    final url = 'https://anime-rift.com/anime/$id';
    final title = row['title'];
    if (title is String && title.trim().isNotEmpty) {
      final image = row['main_picture'] ?? row['medium_picture'];
      return MultimediaItem(
        title: title.trim(),
        url: url,
        posterUrl: _safeArtwork(image),
        provider: animeRiftProviderId,
        contentType: MultimediaContentType.anime,
      );
    }
    if (hydrate == null) return null;
    MultimediaItem? resolved;
    try {
      resolved = await (cache.containsKey(url)
          ? Future.value(cache[url])
          : hydrate(url));
    } on AnimeRiftAuthenticationRequired {
      rethrow;
    } on AnimeRiftAccessUnavailable {
      return null;
    }
    cache[url] = resolved;
    return resolved?.provider == animeRiftProviderId && resolved?.url == url
        ? resolved
        : null;
  }

  String _safeArtwork(Object? value) {
    if (value is! String) return '';
    final uri = Uri.tryParse(value);
    return uri?.scheme == 'https' &&
            uri?.host.isNotEmpty == true &&
            uri!.userInfo.isEmpty &&
            !uri.hasQuery &&
            !uri.hasFragment
        ? value
        : '';
  }

  /// Checks overview, favorite anime and latest watch history. More requests
  /// require explicit opt-in; no results are cached for subsequent accounts.
  Future<AnimeRiftCloudInspection> inspect({
    bool includeLists = false,
    bool includeFullWatchHistory = false,
  }) async {
    final previousAccount = AnimeRiftLocalAccountScope.accountHash;
    final restored = await _reader.restoreAccountSession();
    final accountHash = AnimeRiftLocalAccountScope.accountHash;
    if (!restored ||
        accountHash == null ||
        (previousAccount != null && accountHash != previousAccount)) {
      throw const AnimeRiftAuthenticationRequired();
    }

    final resources = <String, AnimeRiftCloudResourceInspection>{};
    Map<String, int> overviewCounts = const {};

    final overview = await _probe(accountHash, _reader.fetchMyListOverview);
    resources['my_list/overview'] = overview.$1;
    if (overview.$2?['items'] is Map) {
      overviewCounts = parseMyListOverviewCounts(overview.$2!);
    }

    resources['favorite/anime/all'] = (await _probe(
      accountHash,
      _reader.fetchFavoriteAnime,
    )).$1;
    resources['watch_history/latest'] = (await _probe(
      accountHash,
      _reader.fetchWatchHistoryLatest,
    )).$1;

    if (includeLists) {
      for (final category in listCategories) {
        resources['my_list/all:$category'] = (await _probe(
          accountHash,
          () => _reader.fetchMyList(category),
        )).$1;
      }
    }
    if (includeFullWatchHistory) {
      resources['watch_history/full'] = (await _probe(
        accountHash,
        _reader.fetchWatchHistoryFull,
      )).$1;
    }

    _requireAccount(accountHash);
    return AnimeRiftCloudInspection._(accountHash, overviewCounts, resources);
  }

  Future<(AnimeRiftCloudResourceInspection, Map<String, dynamic>?)> _probe(
    String accountHash,
    Future<Map<String, dynamic>> Function() request,
  ) async {
    _requireAccount(accountHash);
    try {
      final response = await request();
      _requireAccount(accountHash);
      final items = response['items'];
      if (items is List) {
        return (
          AnimeRiftCloudResourceInspection(
            AnimeRiftCloudResponseShape.itemsList,
            returnedListLength: items.length,
          ),
          response,
        );
      }
      return (
        AnimeRiftCloudResourceInspection(
          items is Map
              ? AnimeRiftCloudResponseShape.itemsMap
              : AnimeRiftCloudResponseShape.unrecognized,
        ),
        response,
      );
    } on AnimeRiftAuthenticationRequired {
      rethrow;
    } on AnimeRiftAccessUnavailable catch (error) {
      _requireAccount(accountHash);
      if (error.statusCode == 401 || error.statusCode == 403) {
        throw AnimeRiftAuthenticationRequired(statusCode: error.statusCode);
      }
      return (
        const AnimeRiftCloudResourceInspection(
          AnimeRiftCloudResponseShape.unavailable,
        ),
        null,
      );
    }
  }

  void _requireAccount(String expected) {
    if (AnimeRiftLocalAccountScope.accountHash != expected) {
      throw const AnimeRiftAuthenticationRequired();
    }
  }
}
