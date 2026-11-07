import 'dart:convert';

import '../domain/entity/multimedia_item.dart';
import '../extensions/providers/anime_rift_api_client.dart';
import 'library_category.dart';
import 'provider_local_history.dart';
import 'provider_local_library.dart';
import 'anime_rift_account_scope.dart';
import 'anime_rift_cloud_pending.dart';
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

/// The native list API may return a single page for large account libraries.
/// This opt-in read-only interface avoids changing existing reader contracts.
abstract class AnimeRiftCloudPagedReader {
  Future<Map<String, dynamic>> fetchMyListPage(String category, int page);

  Future<Map<String, dynamic>> fetchFavoriteAnimePage(int page);
}

/// Adapter for the authenticated, read-only endpoints of the real API client.
class AnimeRiftCloudApiReader
    implements AnimeRiftCloudAccountReader, AnimeRiftCloudPagedReader {
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
  Future<Map<String, dynamic>> fetchMyListPage(String category, int page) =>
      api.fetchMyListPage(category, page);

  @override
  Future<Map<String, dynamic>> fetchFavoriteAnimePage(int page) =>
      api.fetchFavoriteAnimePage(page);

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
    this.changed = 0,
  });

  final int favorites;
  final int categories;
  final int history;
  final int skipped;

  /// Actual local writes, distinct from the number of remote rows parsed.
  final int changed;
}

/// Paging metadata for the currently linked account only.
class AnimeRiftCloudListPage {
  const AnimeRiftCloudListPage({
    required this.totalCount,
    required this.loadedCount,
    required this.hasMore,
  });
  final int? totalCount;
  final int loadedCount;
  final bool hasMore;
}

class _CloudListCursor {
  _CloudListCursor(
    this.rows,
    this.total,
    this.hasMore, {
    List<Object?> bufferedRows = const [],
    this.serverHasMore = false,
  }) : buffered = List<Object?>.from(bufferedRows);
  final List<Object?> rows;
  final List<Object?> buffered;
  final int? total;
  bool hasMore;
  bool serverHasMore;
  int nextPage = 1;
  bool loading = false;
}

/// Inspects remote counts and imports verified account lists additively.
/// The server's anime/episode row structure is not fully documented, so
/// unknown rows are skipped; existing local data is never removed.
class AnimeRiftCloudSync {
  AnimeRiftCloudSync(this._reader);

  final AnimeRiftCloudAccountReader _reader;
  String? _cursorAccount;
  Map<String, int> _overviewTotals = const {};
  final _cursors = <String, _CloudListCursor>{};
  final _selectedUrls = <String, List<String>>{};
  final _selectedRequests = <String, Future<AnimeRiftCloudImportResult>>{};

  String _listForCategory(LibraryCategory category) =>
      category == LibraryCategory.favorite
      ? 'favorite'
      : _categoryForList.entries
            .firstWhere((entry) => entry.value == category)
            .key;

  AnimeRiftCloudListPage? selectedListPage(LibraryCategory category) {
    if (_cursorAccount != AnimeRiftLocalAccountScope.accountHash) return null;
    final cursor = _cursors[_listForCategory(category)];
    return cursor == null
        ? null
        : AnimeRiftCloudListPage(
            totalCount: cursor.total,
            loadedCount: cursor.rows.length,
            hasMore: cursor.hasMore,
          );
  }

  int? serverListTotal(LibraryCategory category) {
    if (_cursorAccount != AnimeRiftLocalAccountScope.accountHash) return null;
    final list = _listForCategory(category);
    return _overviewTotals[list == 'favorite'
        ? 'my_list_favorites'
        : _overviewForList[list]!];
  }

  List<String>? selectedListUrls(LibraryCategory category) {
    if (_cursorAccount != AnimeRiftLocalAccountScope.accountHash) return null;
    return _selectedUrls[_listForCategory(category)];
  }

  static const listCategories = <String>[
    'favorite',
    'currently',
    'want_to',
    'finished',
    'later',
    'dropped',
  ];

  static const _categoryForList = <String, LibraryCategory>{
    'currently': LibraryCategory.watching,
    'want_to': LibraryCategory.planToWatch,
    'finished': LibraryCategory.completed,
    'later': LibraryCategory.continueLater,
    'dropped': LibraryCategory.notInterested,
  };

  static const _overviewForList = <String, String>{
    'currently': 'my_list_currently_watching',
    'want_to': 'my_list_plan_to_watch',
    'finished': 'my_list_finished_watching',
    'later': 'my_list_on_hold',
    'dropped': 'my_list_dropped',
  };

  /// A refresh reads only the first server page. Further reads are driven by
  /// scrolling, never by startup/background synchronization.
  Future<Map<String, dynamic>> _expandAccountPages({
    required Map<String, dynamic> first,
    required String account,
    required int? expectedCount,
    required Future<Map<String, dynamic>> Function(int page)? loadPage,
    required String list,
    bool loadNextPage = false,
  }) async {
    _requireAccount(account);
    if (_cursorAccount != account) {
      _cursors.clear();
      _overviewTotals = const {};
      _selectedUrls.clear();
      _cursorAccount = account;
    }
    var cursor = _cursors[list];
    if (!loadNextPage || cursor == null) {
      final allRows = _cloudRows(first);
      final rows = allRows.take(30).toList();
      cursor = _CloudListCursor(
        rows,
        expectedCount,
        _hasMore(first) ||
            allRows.length > rows.length ||
            (expectedCount != null && rows.length < expectedCount),
        bufferedRows: allRows.skip(30).toList(),
        serverHasMore: _hasMore(first),
      );
      _cursors[list] = cursor;
    } else if (cursor.hasMore && cursor.buffered.isNotEmpty) {
      // The server can send its entire library in one response, ignoring the
      // requested page. Never discard rows 31+ or repeatedly GET page one.
      final take = cursor.buffered.take(30).toList();
      cursor.rows.addAll(take);
      cursor.buffered.removeRange(0, take.length);
      cursor.hasMore =
          cursor.buffered.isNotEmpty ||
          (cursor.total != null
              ? cursor.rows.length < cursor.total!
              : cursor.serverHasMore);
    } else if (cursor.hasMore && !cursor.loading && loadPage != null) {
      cursor.loading = true;
      try {
        // The default endpoint can mean page 0 or 1. Tolerate exactly one
        // duplicate default page, without scanning the rest of the library.
        for (
          var attempt = 0;
          attempt < 2 && cursor.nextPage <= 256;
          attempt++
        ) {
          final response = await loadPage(cursor.nextPage);
          _requireAccount(account);
          if (!identical(_cursors[list], cursor)) {
            throw const AnimeRiftAccessUnavailable();
          }
          final incoming = _cloudRows(response);
          final keys = cursor.rows.map(_rowIdentity).toSet();
          final added = incoming
              .where((row) => keys.add(_rowIdentity(row)))
              .toList();
          cursor.nextPage++;
          cursor.rows.addAll(added.take(30));
          cursor.buffered.addAll(added.skip(30));
          cursor.serverHasMore = _hasMore(response);
          cursor.hasMore =
              incoming.isNotEmpty &&
              (cursor.buffered.isNotEmpty ||
                  (cursor.total != null
                      ? cursor.rows.length < cursor.total!
                      : cursor.serverHasMore));
          if (added.isNotEmpty || !cursor.hasMore) break;
          if (attempt == 1) cursor.hasMore = false;
        }
        if (cursor.nextPage > 256) cursor.hasMore = false;
      } finally {
        cursor.loading = false;
      }
    }
    return {
      'items': List<Object?>.from(cursor.rows),
      'hasNext': cursor.hasMore,
    };
  }

  String _rowIdentity(Object? row) {
    if (row is Map) {
      final inner = row['anime'] is Map
          ? row['anime'] as Map
          : row['_anime'] is Map
          ? row['_anime'] as Map
          : row;
      final id =
          inner['anime_id'] ??
          inner['animeId'] ??
          inner['_id'] ??
          inner['id'] ??
          row['anime_id'] ??
          row['animeId'];
      if (id is String && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
        return 'anime:$id';
      }
    }
    return 'row:${jsonEncode(row)}';
  }

  /// The native Rift library fetches a single list when selected. Refresh
  /// only that shelf, retaining cached items while the GET runs. A remote
  /// deletion is applied only to previously imported items and only if the
  /// response has every row reported by the server's overview.
  Future<AnimeRiftCloudImportResult> importSelectedList({
    required StorageService storage,
    required LibraryCategory category,
    bool loadNextPage = false,
    Future<MultimediaItem?> Function(String catalogUrl)? hydrate,
  }) {
    final key =
        '${AnimeRiftLocalAccountScope.accountHash}:${category.storageKey}';
    return _selectedRequests.putIfAbsent(key, () {
      final request = _importSelectedList(
        storage: storage,
        category: category,
        loadNextPage: loadNextPage,
        hydrate: hydrate,
      );
      // The map value is itself the completed Future. Returning it from
      // whenComplete makes that Future wait for itself indefinitely.
      return request.whenComplete(() {
        _selectedRequests.remove(key);
      });
    });
  }

  Future<AnimeRiftCloudImportResult> _importSelectedList({
    required StorageService storage,
    required LibraryCategory category,
    required bool loadNextPage,
    Future<MultimediaItem?> Function(String catalogUrl)? hydrate,
  }) async {
    final previous = AnimeRiftLocalAccountScope.accountHash;
    if (!await _reader.restoreAccountSession()) {
      throw const AnimeRiftAuthenticationRequired();
    }
    final account = AnimeRiftLocalAccountScope.accountHash;
    if (account == null || (previous != null && previous != account)) {
      throw const AnimeRiftAuthenticationRequired();
    }
    final list = category == LibraryCategory.favorite
        ? 'favorite'
        : _categoryForList.entries
              .firstWhere((entry) => entry.value == category)
              .key;
    final hasCursor = _cursorAccount == account && _cursors.containsKey(list);
    final first = loadNextPage && hasCursor
        ? <String, dynamic>{'items': <Object?>[]}
        : list == 'favorite'
        ? await _reader.fetchFavoriteAnime()
        : await _reader.fetchMyList(list);
    _requireAccount(account);
    // Scrolling another 30 posters must not refetch the same overview and
    // hold the grid behind an unrelated account summary request.
    Map<String, int> counts =
        loadNextPage && hasCursor && _overviewTotals.isNotEmpty
        ? _overviewTotals
        : const {};
    if (counts.isEmpty) {
      try {
        counts = parseMyListOverviewCounts(await _reader.fetchMyListOverview());
        _requireAccount(account);
      } on AnimeRiftAccessUnavailable {
        _requireAccount(account);
      }
    }
    final countKey = category == LibraryCategory.favorite
        ? 'my_list_favorites'
        : _overviewForList[list]!;
    final pagedReader = _reader is AnimeRiftCloudPagedReader
        ? _reader as AnimeRiftCloudPagedReader
        : null;
    final response = await _expandAccountPages(
      first: first,
      list: list,
      loadNextPage: loadNextPage,
      account: account,
      expectedCount: counts[countKey],
      loadPage: pagedReader == null
          ? null
          : (page) => list == 'favorite'
                ? pagedReader.fetchFavoriteAnimePage(page)
                : pagedReader.fetchMyListPage(list, page),
    );
    _requireAccount(account);
    if (counts.isNotEmpty) _overviewTotals = Map.unmodifiable(counts);
    final rows = _cloudRows(response);
    final library = ProviderLocalLibrary(storage, animeRiftProviderId);
    final localItems = {for (final item in library.allItems()) item.url: item};
    final hydrated = <String, MultimediaItem?>{};
    final received = <String, MultimediaItem>{};
    var skipped = 0;
    for (final row in rows) {
      // Listing 290 items must not trigger 290 serial detail requests and
      // silently drop the remainder if the catalog rate-limits them.
      final item = await _cloudAnime(
        row,
        rows.length <= 30 && (counts[countKey] ?? rows.length) <= 30
            ? hydrate
            : null,
        hydrated,
        cached: (url) => localItems[url],
      );
      _requireAccount(account);
      if (item == null) {
        skipped++;
      } else {
        received[item.url] = item;
      }
    }
    final journal = AnimeRiftCloudPendingJournal(storage);
    final kind = category == LibraryCategory.favorite ? 'favorite' : 'category';
    final protectedUrls = {
      for (final mutation in journal.pending(account))
        if (mutation.kind == kind) mutation.url,
    };
    final complete =
        counts[countKey] == rows.length &&
        received.length == rows.length &&
        !_hasMore(response);
    final isFavorite = category == LibraryCategory.favorite;
    final key = isFavorite
        ? 'animerift_cloud_favorites_v1:$account'
        : 'animerift_cloud_categories_v1:$account';
    Set<String> previousFavorites = {};
    Map<String, String> previousCategories = {};
    Set<String> absentUrls = {};
    if (complete) {
      try {
        if (isFavorite) {
          previousFavorites = _favoriteSnapshot(storage.getString(key)) ?? {};
        } else {
          previousCategories = _storageSnapshot(storage.getString(key)) ?? {};
        }
      } on Object {
        // A corrupt old snapshot cannot authorize a remote deletion.
      }
      final prior = isFavorite
          ? previousFavorites
          : {
              for (final entry in previousCategories.entries)
                if (entry.value == category.storageKey) entry.key,
            };
      absentUrls = prior.difference(received.keys.toSet());
    }
    _requireAccount(account);
    final changed = await library.applyCloudItems(
      category: category,
      received: received.values,
      protectedUrls: protectedUrls,
      absentUrls: absentUrls,
    );
    _requireAccount(account);
    if (complete) {
      if (isFavorite) {
        await storage.setString(
          key,
          jsonEncode({
            'version': 1,
            'favorites': received.keys.toList()..sort(),
          }),
        );
      } else {
        final merged = Map<String, String>.from(previousCategories)
          ..removeWhere((_, value) => value == category.storageKey);
        for (final url in received.keys) {
          merged[url] = category.storageKey;
        }
        await storage.setString(
          key,
          jsonEncode({'version': 1, 'categories': merged}),
        );
      }
      _requireAccount(account);
    }
    // Use the remote page's exact order/identity for the visible grid. A
    // pre-existing local cache may contain hundreds of unrelated older rows.
    _selectedUrls[list] = List.unmodifiable(received.keys);
    return AnimeRiftCloudImportResult(
      favorites: category == LibraryCategory.favorite ? received.length : 0,
      categories: category == LibraryCategory.favorite ? 0 : received.length,
      history: 0,
      skipped: skipped,
      changed: changed,
    );
  }

  /// Read the Rift watch-history endpoint independently of library shelves.
  /// History and resume remain cached, and local playback seconds are never
  /// overwritten by the remote last-episode number.
  Future<AnimeRiftCloudImportResult> importHistoryToLocal({
    required StorageService storage,
    Future<MultimediaItem?> Function(String catalogUrl)? hydrate,
  }) async {
    final previous = AnimeRiftLocalAccountScope.accountHash;
    if (!await _reader.restoreAccountSession()) {
      throw const AnimeRiftAuthenticationRequired();
    }
    final account = AnimeRiftLocalAccountScope.accountHash;
    if (account == null || (previous != null && previous != account)) {
      throw const AnimeRiftAuthenticationRequired();
    }
    final rows = _cloudRows(await _readWatchHistory());
    _requireAccount(account);
    final history = ProviderLocalHistory(storage, animeRiftProviderId);
    final library = ProviderLocalLibrary(storage, animeRiftProviderId);
    final pending = AnimeRiftCloudPendingJournal(storage);
    final existing = history.history().map((entry) => entry.item.url).toSet();
    final clearPending = pending.hasPending(account, '', 'history-clear');
    final hydrated = <String, MultimediaItem?>{};
    var changed = 0;
    var skipped = 0;
    for (final row in rows) {
      // Long watch histories must not open hundreds of details connections in
      // sequence on startup. Show the server title, saved item or verified ID
      // immediately; the detail screen resolves richer metadata on demand.
      final item = await _cloudAnime(
        row,
        rows.length > 30 ? null : hydrate,
        hydrated,
        cached: library.item,
      );
      _requireAccount(account);
      if (item == null) {
        skipped++;
        continue;
      }
      if (clearPending ||
          pending.hasPending(account, item.url, 'history') ||
          pending.hasPending(account, item.url, 'playback')) {
        continue;
      }
      final watched = _remoteWatchedNumbers(row);
      if (watched != null &&
          !pending.hasPending(account, item.url, 'watched')) {
        await history.importRemoteWatched(item.url, watched);
      }
      final raw = row is Map ? row['last_episode_viewed'] : null;
      final number = raw is num
          ? raw
          : raw is Map
          ? raw['episode_number']
          : null;
      final episode =
          number is num &&
              number.isFinite &&
              number == number.toInt() &&
              number > 0 &&
              number <= 100000
          ? number.toInt()
          : null;
      if (existing.add(item.url)) {
        if (episode != null) {
          await history.importRemoteEpisode(item, episode);
        } else {
          await history.recordOpened(item);
        }
        changed++;
      } else if (episode != null &&
          !history.continueWatching().any(
            (entry) => entry.item.url == item.url,
          )) {
        await history.importRemoteEpisode(item, episode);
        changed++;
      }
    }
    _requireAccount(account);
    return AnimeRiftCloudImportResult(
      favorites: 0,
      categories: 0,
      history: rows.length - skipped,
      skipped: skipped,
      changed: changed,
    );
  }

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
    final pending = AnimeRiftCloudPendingJournal(storage);

    // Fetch before writing, so a failed request never looks like an empty
    // remote library and a changed session cannot import into another user.
    // The count from the overview is also the page-completeness boundary.
    // Without it, the default first 30 rows may silently look like the
    // entire library, especially on accounts with hundreds of completed anime.
    Map<String, int> counts = const {};
    try {
      counts = parseMyListOverviewCounts(await _reader.fetchMyListOverview());
      _requireAccount(account);
    } on AnimeRiftAccessUnavailable {
      _requireAccount(account);
    }
    final pagedReader = _reader is AnimeRiftCloudPagedReader
        ? _reader as AnimeRiftCloudPagedReader
        : null;
    final favoriteResponse = await _expandAccountPages(
      list: 'favorite',
      first: await _reader.fetchFavoriteAnime(),
      account: account,
      expectedCount: counts['my_list_favorites'],
      loadPage: pagedReader?.fetchFavoriteAnimePage,
    );
    final remoteFavorites = _cloudRows(favoriteResponse);
    _requireAccount(account);
    final remoteLists = <LibraryCategory, List<Object?>>{};
    final remoteResponses = <String, Map<String, dynamic>>{};
    for (final entry in _categoryForList.entries) {
      final response = await _expandAccountPages(
        list: entry.key,
        first: await _reader.fetchMyList(entry.key),
        account: account,
        expectedCount: counts[_overviewForList[entry.key]],
        loadPage: pagedReader == null
            ? null
            : (page) => pagedReader.fetchMyListPage(entry.key, page),
      );
      remoteResponses[entry.key] = response;
      remoteLists[entry.value] = _cloudRows(response);
      _requireAccount(account);
    }
    final remoteHistory = _cloudRows(await _readWatchHistory());
    _requireAccount(account);

    final hydrated = <String, MultimediaItem?>{};
    var skipped = 0;
    Future<MultimediaItem?> parse(Object? row, {bool largeList = false}) async {
      final item = await _cloudAnime(
        row,
        largeList ? null : hydrate,
        hydrated,
        cached: library.item,
      );
      _requireAccount(account);
      if (item == null) skipped++;
      return item;
    }

    final favorites = <MultimediaItem>[];
    for (final row in remoteFavorites) {
      final item = await parse(row, largeList: remoteFavorites.length > 30);
      if (item != null) favorites.add(item);
    }
    final categories = <LibraryCategory, List<MultimediaItem>>{};
    for (final entry in remoteLists.entries) {
      final mapped = <MultimediaItem>[];
      for (final row in entry.value) {
        final item = await parse(row, largeList: entry.value.length > 30);
        if (item != null) mapped.add(item);
      }
      categories[entry.key] = mapped;
    }
    final watched = <(MultimediaItem, int?, Map<int, bool>?)>[];
    for (final row in remoteHistory) {
      final item = await parse(row, largeList: remoteHistory.length > 30);
      if (item != null) {
        final raw = row is Map ? row['last_episode_viewed'] : null;
        final number = raw is num
            ? raw
            : raw is Map
            ? raw['episode_number']
            : null;
        final episode =
            number is num &&
                number.isFinite &&
                number == number.toInt() &&
                number > 0 &&
                number <= 100000
            ? number.toInt()
            : null;
        watched.add((item, episode, _remoteWatchedNumbers(row)));
      }
    }

    _requireAccount(account);
    var changed = 0;
    for (final item in favorites) {
      _requireAccount(account);
      // A locally removed favorite must not reappear during an offline sync.
      if (pending.hasPending(account, item.url, 'favorite')) continue;
      if (!library.isFavorite(item.url)) {
        await library.setFavorite(item, true);
        changed++;
      }
    }
    final completeFavorites =
        counts['my_list_favorites'] == remoteFavorites.length &&
        favorites.length == remoteFavorites.length &&
        !_hasMore(favoriteResponse);
    if (completeFavorites) {
      final baselineKey = 'animerift_cloud_favorites_v1:$account';
      Set<String> previous = {};
      try {
        previous = _favoriteSnapshot(storage.getString(baselineKey)) ?? {};
      } on Object {
        // Untrusted/corrupt snapshot never authorizes a local deletion.
      }
      final remote = favorites.map((item) => item.url).toSet();
      for (final url in previous.difference(remote)) {
        _requireAccount(account);
        if (pending.hasPending(account, url, 'favorite')) continue;
        final item = library.item(url);
        if (item != null && library.isFavorite(url)) {
          await library.setFavorite(item, false);
          changed++;
        }
      }
      _requireAccount(account);
      await storage.setString(
        baselineKey,
        jsonEncode({'version': 1, 'favorites': remote.toList()..sort()}),
      );
      _requireAccount(account);
    }
    // A title moved on another device must change categories locally, not
    // just appear the first time. A pending local edit always wins, and an
    // ambiguous multi-list response must not choose a category arbitrarily.
    final remoteCategories = <String, (MultimediaItem, LibraryCategory)>{};
    final ambiguous = <String>{};
    for (final entry in categories.entries) {
      for (final item in entry.value) {
        final previous = remoteCategories[item.url];
        if (previous != null && previous.$2 != entry.key) {
          ambiguous.add(item.url);
        } else {
          remoteCategories[item.url] = (item, entry.key);
        }
      }
    }
    final completeLists =
        ambiguous.isEmpty &&
        _categoryForList.entries.every((entry) {
          final rows = remoteLists[entry.value]!;
          final accepted = categories[entry.value]!;
          final response = remoteResponses[entry.key]!;
          return counts[_overviewForList[entry.key]] == rows.length &&
              accepted.length == rows.length &&
              !_hasMore(response);
        });
    final baselineKey = 'animerift_cloud_categories_v1:$account';
    Map<String, String> previousSnapshot = {};
    if (completeLists) {
      try {
        final raw = _storageSnapshot(storage.getString(baselineKey));
        previousSnapshot = raw ?? {};
      } on Object {
        // Corrupt snapshots cannot authorize a remote delete.
      }
    }
    for (final entry in remoteCategories.entries) {
      _requireAccount(account);
      if (ambiguous.contains(entry.key) ||
          pending.hasPending(account, entry.key, 'category')) {
        continue;
      }
      final (item, category) = entry.value;
      if (library.category(item.url) != category) {
        await library.setCategory(item, category);
        changed++;
      }
    }
    if (completeLists) {
      for (final entry in previousSnapshot.entries) {
        _requireAccount(account);
        if (remoteCategories.containsKey(entry.key) ||
            pending.hasPending(account, entry.key, 'category')) {
          continue;
        }
        final previous = LibraryCategory.fromStorageKey(entry.value);
        // Only remove an item this same account previously imported, when
        // it still has exactly that remote category. Preserve local-only rows.
        if (library.category(entry.key) == previous) {
          await library.clearCategory(entry.key);
          changed++;
        }
      }
      _requireAccount(account);
      await storage.setString(
        baselineKey,
        jsonEncode({
          'version': 1,
          'categories': {
            for (final entry in remoteCategories.entries)
              entry.key: entry.value.$2.storageKey,
          },
        }),
      );
      _requireAccount(account);
    }
    final knownHistory = history
        .history()
        .map((entry) => entry.item.url)
        .toSet();
    final historyWasCleared = pending.hasPending(account, '', 'history-clear');
    for (final (item, episode, viewedStates) in watched) {
      _requireAccount(account);
      if (historyWasCleared ||
          pending.hasPending(account, item.url, 'history') ||
          pending.hasPending(account, item.url, 'playback')) {
        continue;
      }
      if (viewedStates != null &&
          !pending.hasPending(account, item.url, 'watched')) {
        await history.importRemoteWatched(item.url, viewedStates);
      }
      if (knownHistory.add(item.url)) {
        if (episode != null) {
          await history.importRemoteEpisode(item, episode);
        } else {
          await history.recordOpened(item);
        }
        changed++;
      } else if (episode != null &&
          !history.continueWatching().any(
            (entry) => entry.item.url == item.url,
          )) {
        // An older title-only import can be enriched once the original Rift
        // record exposes its last watched episode; preserve local progress.
        await history.importRemoteEpisode(item, episode);
        changed++;
      }
    }
    _requireAccount(account);
    return AnimeRiftCloudImportResult(
      favorites: favorites.length,
      categories: categories.values.fold<int>(0, (n, rows) => n + rows.length),
      history: watched.length,
      skipped: skipped,
      changed: changed,
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

  Map<int, bool>? _remoteWatchedNumbers(Object? row) {
    if (row is! Map) return null;
    final watched = row['watched_episodes'];
    final unviewed = row['not_watched_episodes'];
    // Some watch-history records carry just the last *viewed* episode rather
    // than the full two arrays. This proves at most one viewed episode; never
    // mark an inferred range (1..last), which could corrupt skipped episodes.
    final last = row['last_episode_viewed'];
    final knownLast = _explicitEpisodeNumber(last);
    if (watched is! List && unviewed is! List) {
      return knownLast == null ? null : {knownLast: true};
    }
    final states = <int, bool>{};
    bool collect(List<dynamic> items, bool value) {
      for (final item in items) {
        final number = _explicitEpisodeNumber(item);
        if (number == null ||
            (states.containsKey(number) && states[number] != value)) {
          return false;
        }
        states[number] = value;
      }
      return true;
    }

    if (watched is List && !collect(watched, true)) return null;
    if (unviewed is List && !collect(unviewed, false)) return null;
    // Explicit unviewed overrides an older last-interaction pointer.
    if (knownLast != null) states.putIfAbsent(knownLast, () => true);
    return states;
  }

  int? _explicitEpisodeNumber(Object? value) {
    final raw = value is Map ? value['episode_number'] : value;
    final number = raw is num
        ? raw
        : raw is String && RegExp(r'^\d{1,6}$').hasMatch(raw)
        ? int.tryParse(raw)
        : null;
    return number != null &&
            number.isFinite &&
            number == number.toInt() &&
            number > 0 &&
            number <= 100000
        ? number.toInt()
        : null;
  }

  Map<String, String>? _storageSnapshot(String? raw) {
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['categories'] is! Map) {
      throw const FormatException('Invalid Rift cloud category snapshot');
    }
    final result = <String, String>{};
    (decoded['categories'] as Map).forEach((dynamic url, dynamic value) {
      if (url is! String ||
          value is! String ||
          AnimeRiftCloudPendingJournal.catalogUrl(url) != url ||
          !LibraryCategory.primaryValues.any(
            (category) => category.storageKey == value,
          )) {
        throw const FormatException('Invalid Rift cloud category entry');
      }
      result[url] = value;
    });
    return result;
  }

  bool _hasMore(Map<String, dynamic> response) {
    final payload = response['items'];
    return response['hasNext'] == true ||
        (payload is Map && payload['hasNext'] == true);
  }

  Set<String>? _favoriteSnapshot(String? raw) {
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['favorites'] is! List) {
      throw const FormatException('Invalid Rift cloud favorite snapshot');
    }
    final result = <String>{};
    for (final url in decoded['favorites'] as List) {
      if (url is! String ||
          AnimeRiftCloudPendingJournal.catalogUrl(url) != url) {
        throw const FormatException('Invalid Rift cloud favorite entry');
      }
      result.add(url);
    }
    return result;
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
    Map<String, MultimediaItem?> cache, {
    MultimediaItem? Function(String url)? cached,
  }) async {
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
        ? row['_id'] ?? row['anime_id'] ?? row['animeId'] ?? row['id']
        : value['anime_id'] ??
              value['animeId'] ??
              value['_anime'] ??
              value['anime'] ??
              value['_id'] ??
              value['id'];
    if (id is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      return null;
    }
    final url = 'https://anime-rift.com/anime/$id';
    final title =
        row['title'] ??
        row['name'] ??
        row['anime_title'] ??
        row['english_title'] ??
        row['title_en'];
    final saved = cached?.call(url);
    final picture = _safeArtwork(
      row['main_picture'] ??
          row['medium_picture'] ??
          row['poster_url'] ??
          row['poster'] ??
          row['image'],
    );
    if (title is String && title.trim().isNotEmpty) {
      return MultimediaItem(
        title: title.trim(),
        url: url,
        posterUrl: picture.isNotEmpty ? picture : saved?.posterUrl ?? '',
        provider: animeRiftProviderId,
        contentType: MultimediaContentType.anime,
      );
    }
    if (saved != null) return saved;
    MultimediaItem? resolved;
    if (hydrate != null) {
      try {
        resolved = await (cache.containsKey(url)
            ? Future.value(cache[url])
            : hydrate(url));
      } on AnimeRiftAuthenticationRequired {
        rethrow;
      } on AnimeRiftAccessUnavailable {
        // This row still identifies a real catalog anime. A failed details
        // request must not silently remove it from the user's library.
      }
    }
    cache[url] = resolved;
    if (resolved?.provider == animeRiftProviderId && resolved?.url == url) {
      return resolved;
    }
    // Use the verified catalog ID as a temporary label, never an unrelated
    // title or invented poster. Opening the card fetches actual details.
    return MultimediaItem(
      title: id,
      url: url,
      posterUrl: picture,
      provider: animeRiftProviderId,
      contentType: MultimediaContentType.anime,
    );
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
      // Only an expired credential is an authentication failure. A 403 can be
      // an access policy/device restriction while the linked session remains
      // valid; surface it as an access failure instead of claiming sign-out.
      if (error.statusCode == 401) {
        throw AnimeRiftAuthenticationRequired(statusCode: error.statusCode);
      }
      if (error.statusCode == 403) rethrow;
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
