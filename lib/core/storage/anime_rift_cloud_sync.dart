import '../extensions/providers/anime_rift_api_client.dart';
import 'anime_rift_account_scope.dart';

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

/// Read-only first step toward cloud sync. AOT confirms the overview counter
/// keys and endpoint paths, but not the server's anime/episode row structure.
/// Therefore an inspection can never reconcile or delete local/cloud data.
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
