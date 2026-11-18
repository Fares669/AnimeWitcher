import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_sync_ids.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/services/app_diagnostics.dart';
import '../../../../core/storage/library_category.dart';
import '../../../../core/storage/library_repository.dart';
import '../../../../core/storage/storage_service.dart';
import './library_auth.dart';
import './library_media_kind.dart';
import './library_state.dart';

part 'library_provider.g.dart';

/// The server total is independent of the number of cards loaded on screen.
class LibraryShelfPageInfo {
  const LibraryShelfPageInfo({
    required this.loaded,
    required this.hasMore,
    required this.loading,
    this.loadFailed = false,
    this.total,
  });

  final int loaded;
  final int? total;
  final bool hasMore;
  final bool loading;
  final bool loadFailed;
}

class _LibraryShelfCursorState {
  int visibleLimit = Library.pageSize;
  int cachedLocalCount = 0;
  int? total;
  bool loading = false;
  bool loadFailed = false;
  bool hasMore = false;
  bool receivedRemotePage = false;
  int mutationVersion = 0;
  AnimeWitcherLibraryCursor? cursor;
  final List<MultimediaItem> items = <MultimediaItem>[];
}

@Riverpod(keepAlive: true)
class Library extends _$Library {
  static const int pageSize = 30;

  final _pages = <String, _LibraryShelfCursorState>{};
  final _confirmedCounts = <String, Map<LibraryCategory, int>>{};
  final _countRequests = <String, Future<void>>{};
  final _inFlightCountDeltas = <String, Map<LibraryCategory, int>>{};

  int _countRevision = 0;
  int get countRevision => _countRevision;
  int _pageRevision = 0;
  int get pageRevision => _pageRevision;
  int _selectionGeneration = 0;

  String? get _accountUid =>
      ref.read(animeWitcherAccountServiceProvider).accountUid;

  String _pageKey(LibraryMediaKind kind, LibraryCategory category) =>
      'native:${_accountUid ?? 'guest'}:${kind.storageKey}:${category.storageKey}';

  String _countsKey(LibraryMediaKind kind) =>
      '${_pageKey(kind, LibraryCategory.watching)}:counts';

  _LibraryShelfCursorState _page(
    LibraryMediaKind kind,
    LibraryCategory category,
  ) => _pages.putIfAbsent(
    _pageKey(kind, category),
    _LibraryShelfCursorState.new,
  );

  List<MultimediaItem> _localItems(
    LibraryMediaKind kind,
    LibraryCategory category,
  ) => filterLibraryItemsByKind(
    ref.read(libraryRepositoryProvider).getLibraryItems(category: category),
    kind,
  );

  int? _cachedCategoryCount(LibraryMediaKind kind, LibraryCategory category) {
    final owner = _accountUid;
    if (owner == null || owner.isEmpty) return null;
    return ref
        .read(storageServiceProvider)
        .getCachedLibraryCounts(
          providerKey: 'native',
          accountKey: owner,
          mediaKindKey: kind.storageKey,
        )[category.storageKey];
  }

  Future<void> _saveCachedCategoryCounts(
    LibraryMediaKind kind,
    Map<LibraryCategory, int> counts,
  ) async {
    final owner = _accountUid;
    if (owner == null || owner.isEmpty || counts.isEmpty) return;
    await ref
        .read(storageServiceProvider)
        .setCachedLibraryCounts(
          providerKey: 'native',
          accountKey: owner,
          mediaKindKey: kind.storageKey,
          counts: {
            for (final entry in counts.entries)
              entry.key.storageKey: entry.value,
          },
        );
  }

  /// Counts are loaded on opening a shelf, never during provider construction.
  Future<void> refreshServerCounts(LibraryMediaKind kind) {
    final key = _countsKey(kind);
    if (_confirmedCounts.containsKey(key)) return Future<void>.value();
    final active = _countRequests[key];
    if (active != null) return active;
    final service = ref.read(animeWitcherAccountServiceProvider);
    if (!service.isSignedIn) return Future<void>.value();
    final account = service.accountUid;

    final request = () async {
      try {
        final counts = await service.fetchLibraryCounts(
          manga: kind == LibraryMediaKind.manga,
        );
        if (!ref.mounted ||
            account != service.accountUid ||
            key != _countsKey(kind)) {
          return;
        }
        final deltas = _inFlightCountDeltas.remove(key);
        final adjusted = deltas == null || deltas.isEmpty
            ? counts
            : <LibraryCategory, int>{
                for (final entry in counts.entries)
                  entry.key: (entry.value + (deltas[entry.key] ?? 0)).clamp(
                    0,
                    1 << 30,
                  ),
              };
        _confirmedCounts[key] = adjusted;
        await _saveCachedCategoryCounts(kind, adjusted);
        _countRevision++;
        refresh();
      } catch (_) {
        // An offline count is unknown, not zero. Retry on the next visit.
      }
    }();
    _countRequests[key] = request;
    return request.whenComplete(() {
      _countRequests.remove(key);
      _inFlightCountDeltas.remove(key);
    });
  }

  List<MultimediaItem> _visibleItems(
    LibraryMediaKind kind,
    LibraryCategory category,
  ) {
    final page = _page(kind, category);
    final local = _localItems(kind, category);
    page.cachedLocalCount = local.length;
    // After a successful page, Firestore ordering is authoritative. Older
    // local caches can contain more cards than the requested server page.
    final rows = page.receivedRemotePage ? page.items : local;
    return rows.take(page.visibleLimit).toList(growable: false);
  }

  int? _knownTotal(LibraryMediaKind kind, LibraryCategory category) =>
      _page(kind, category).total ??
      _confirmedCounts[_countsKey(kind)]?[category];

  LibraryShelfPageInfo pageInfo(
    LibraryMediaKind kind,
    LibraryCategory category, {
    int? loadedLocalCount,
  }) {
    final page = _page(kind, category);
    final total = _knownTotal(kind, category);
    final count = page.receivedRemotePage
        ? page.items.length
        : (loadedLocalCount ?? page.cachedLocalCount);
    final loaded = count.clamp(0, page.visibleLimit);
    return LibraryShelfPageInfo(
      loaded: loaded,
      total: total,
      hasMore:
          (total == null || loaded < total) &&
          (page.hasMore ||
              page.loading ||
              page.loadFailed ||
              (!page.receivedRemotePage &&
                  page.cachedLocalCount > page.visibleLimit)),
      loading: page.loading,
      loadFailed: page.loadFailed,
    );
  }

  int? categoryCount(LibraryMediaKind kind, LibraryCategory category) {
    final confirmed = _knownTotal(kind, category);
    if (confirmed != null) return confirmed;
    final localCount = _localItems(kind, category).length;
    if (!ref.read(animeWitcherAccountServiceProvider).isSignedIn) {
      return localCount;
    }
    final cached = _cachedCategoryCount(kind, category);
    if (cached != null) {
      return cached == 0 && localCount > 0 ? localCount : cached;
    }
    if (localCount > 0) return localCount;
    // Do not render an unqueried server shelf as a confirmed empty shelf.
    return null;
  }

  @override
  LibraryState build() {
    ref.watch(accountDataRevisionProvider);
    final kind = LibraryMediaKind.fromStorageKey(
      ref.read(storageServiceProvider).getString('library_media_kind'),
    );
    final category = _categoryFor();
    final items = _visibleItems(kind, category);
    return items.isEmpty
        ? LibraryEmpty(category, kind)
        : LibrarySuccess(items, category, kind);
  }

  List<MultimediaItem> itemsForCategory(
    LibraryMediaKind kind,
    LibraryCategory category,
  ) => _visibleItems(kind, category);

  LibraryCategory get selectedCategory => state.category;
  LibraryMediaKind get selectedMediaKind => state.mediaKind;

  LibraryState refresh({
    LibraryCategory? category,
    LibraryMediaKind? mediaKind,
  }) {
    _pageRevision++;
    final selected = category ?? state.category;
    final selectedKind = mediaKind ?? state.mediaKind;
    final items = _visibleItems(selectedKind, selected);
    state = items.isEmpty
        ? LibraryEmpty(selected, selectedKind)
        : LibrarySuccess(items, selected, selectedKind);
    return state;
  }

  /// Only the first 30 cards are fetched on entry. An expanded shelf retains
  /// its loaded cards and cursor when a fresh first page is requested.
  Future<void> refreshVisibleFromServer({
    LibraryCategory? category,
    LibraryMediaKind? mediaKind,
  }) async {
    final kind = mediaKind ?? state.mediaKind;
    final shelf = category ?? state.category;
    final page = _page(kind, shelf);
    if (page.loading) return;
    final service = ref.read(animeWitcherAccountServiceProvider);
    final account = service.accountUid;
    if (account == null) return;
    for (final media in LibraryMediaKind.values) {
      unawaited(refreshServerCounts(media));
    }
    page.loading = true;
    page.loadFailed = false;
    refresh();
    final key = _pageKey(kind, shelf);
    final mutationVersion = page.mutationVersion;
    final elapsed = Stopwatch()..start();
    try {
      final result = await service
          .fetchLibraryPage(
            category: shelf,
            manga: kind == LibraryMediaKind.manga,
          )
          .timeout(const Duration(seconds: 25));
      if (!ref.mounted ||
          account != service.accountUid ||
          key != _pageKey(kind, shelf) ||
          page.mutationVersion != mutationVersion) {
        return;
      }

      if (page.receivedRemotePage &&
          page.visibleLimit > pageSize &&
          page.items.length > pageSize) {
        final targetLength = result.total < pageSize
            ? result.total
            : page.items.length.clamp(pageSize, result.total);
        final merged = <MultimediaItem>[];
        final seen = <String>{};
        for (final item in result.items) {
          if (seen.add(_mediaIdentity(item.url))) merged.add(item);
        }
        for (final item in page.items) {
          if (merged.length >= targetLength) break;
          if (seen.add(_mediaIdentity(item.url))) merged.add(item);
        }
        page.items
          ..clear()
          ..addAll(merged);
        page.cursor ??= result.nextCursor;
        page.total = result.total;
        page.hasMore =
            page.items.length < result.total &&
            (result.hasMore || page.cursor != null);
        page.visibleLimit = page.items.length.clamp(pageSize, 20000);
      } else {
        page.items
          ..clear()
          ..addAll(result.items);
        page.cursor = result.nextCursor;
        page.total = result.total;
        page.hasMore = result.hasMore;
        page.visibleLimit = pageSize;
      }
      page.receivedRemotePage = true;
      final counts = _confirmedCounts[_countsKey(kind)];
      if (counts != null) {
        counts[shelf] = result.total;
        _countRevision++;
      }
      await _saveCachedCategoryCounts(kind, {shelf: result.total});
    } catch (error) {
      page.loadFailed = true;
      appDiagnostics.record('library.page', {
        'action': 'first',
        'status': error is TimeoutException ? 'timeout' : 'failed',
        'reason': 'native',
        'durationMs': elapsed.elapsedMilliseconds,
        'retryable': true,
      });
    } finally {
      page.loading = false;
      if (!page.loadFailed) {
        appDiagnostics.record('library.page', {
          'action': 'first',
          'status': 'ok',
          'reason': 'native',
          'durationMs': elapsed.elapsedMilliseconds,
          'count': page.visibleLimit,
        });
      }
      if (ref.mounted) refresh();
    }
  }

  /// Next pages are requested only by a visible grid reaching its bottom.
  Future<void> loadNextPage({
    required LibraryMediaKind mediaKind,
    required LibraryCategory category,
  }) async {
    final page = _page(mediaKind, category);
    if (page.loading) return;
    final key = _pageKey(mediaKind, category);
    final service = ref.read(animeWitcherAccountServiceProvider);
    final account = service.accountUid;
    if (account == null) {
      page.visibleLimit += pageSize;
      refresh();
      return;
    }
    if (!page.receivedRemotePage) {
      await refreshVisibleFromServer(category: category, mediaKind: mediaKind);
      if (!ref.mounted || _pageKey(mediaKind, category) != key) return;
      if (!page.receivedRemotePage || page.loadFailed) {
        if (page.cachedLocalCount > page.visibleLimit) {
          page.visibleLimit = (page.visibleLimit + pageSize).clamp(
            pageSize,
            page.cachedLocalCount,
          );
          page.loadFailed = false;
          refresh();
        }
        return;
      }
      if (!page.hasMore || page.visibleLimit > pageSize) return;
    }
    final total = _knownTotal(mediaKind, category);
    if (total != null && page.items.length >= total) {
      page.hasMore = false;
      return;
    }
    if (!page.hasMore) return;
    page.loading = true;
    page.loadFailed = false;
    final mutationVersion = page.mutationVersion;
    refresh();
    final elapsed = Stopwatch()..start();
    try {
      final cursor = page.cursor;
      if (cursor == null) {
        page.loadFailed = true;
        return;
      }
      final result = await service
          .fetchLibraryPage(
            category: category,
            manga: mediaKind == LibraryMediaKind.manga,
            cursor: cursor,
          )
          .timeout(const Duration(seconds: 25));
      if (!ref.mounted ||
          account != service.accountUid ||
          _pageKey(mediaKind, category) != key ||
          page.mutationVersion != mutationVersion) {
        return;
      }
      final seen = page.items.map((item) => _mediaIdentity(item.url)).toSet();
      for (final item in result.items) {
        if (seen.add(_mediaIdentity(item.url))) page.items.add(item);
      }
      page.cursor = result.nextCursor;
      page.hasMore = result.hasMore;
      page.visibleLimit = page.items.length;
      page.total = result.total;
      await _saveCachedCategoryCounts(mediaKind, {category: result.total});
    } catch (error) {
      page.loadFailed = true;
      appDiagnostics.record('library.page', {
        'action': 'next',
        'status': error is TimeoutException ? 'timeout' : 'failed',
        'reason': 'native',
        'durationMs': elapsed.elapsedMilliseconds,
        'retryable': true,
      });
    } finally {
      page.loading = false;
      if (!page.loadFailed) {
        appDiagnostics.record('library.page', {
          'action': 'next',
          'status': 'ok',
          'reason': 'native',
          'durationMs': elapsed.elapsedMilliseconds,
          'count': page.visibleLimit,
        });
      }
      if (ref.mounted) refresh();
    }
  }

  bool _shouldRefreshShelfOnSelect(
    LibraryMediaKind kind,
    LibraryCategory category,
  ) {
    final page = _page(kind, category);
    return !page.receivedRemotePage ||
        page.loadFailed ||
        page.visibleLimit <= pageSize;
  }

  Future<void> selectCategory(LibraryCategory category) async {
    final generation = ++_selectionGeneration;
    final kind = state.mediaKind;
    final account = _accountUid;
    await ref.read(libraryRepositoryProvider).setSelectedCategory(category);
    if (ref.mounted &&
        generation == _selectionGeneration &&
        account == _accountUid) {
      refresh(category: category);
      if (_shouldRefreshShelfOnSelect(kind, category)) {
        unawaited(
          refreshVisibleFromServer(category: category, mediaKind: kind),
        );
      }
    }
  }

  Future<void> select(
    LibraryMediaKind mediaKind,
    LibraryCategory category,
  ) async {
    final generation = ++_selectionGeneration;
    final account = _accountUid;
    await ref
        .read(storageServiceProvider)
        .setString('library_media_kind', mediaKind.storageKey);
    await ref.read(libraryRepositoryProvider).setSelectedCategory(category);
    if (ref.mounted &&
        generation == _selectionGeneration &&
        account == _accountUid) {
      refresh(category: category, mediaKind: mediaKind);
      if (_shouldRefreshShelfOnSelect(mediaKind, category)) {
        unawaited(
          refreshVisibleFromServer(category: category, mediaKind: mediaKind),
        );
      }
    }
  }

  Future<void> selectMediaKind(LibraryMediaKind mediaKind) async {
    final generation = ++_selectionGeneration;
    final account = _accountUid;
    await ref
        .read(storageServiceProvider)
        .setString('library_media_kind', mediaKind.storageKey);
    if (ref.mounted &&
        generation == _selectionGeneration &&
        account == _accountUid) {
      final category = _categoryFor();
      refresh(category: category, mediaKind: mediaKind);
      if (_shouldRefreshShelfOnSelect(mediaKind, category)) {
        unawaited(
          refreshVisibleFromServer(category: category, mediaKind: mediaKind),
        );
      }
    }
  }

  LibraryCategory _categoryFor() =>
      ref.read(libraryRepositoryProvider).getSelectedCategory();

  String _mediaIdentity(String url) {
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(url);
    if (animeId != null) return 'aw:$animeId';
    return url.trim();
  }

  Iterable<LibraryCategory> _loadedNativeCategories(
    String url,
    LibraryMediaKind kind,
  ) sync* {
    final id = _mediaIdentity(url);
    for (final category in LibraryCategory.primaryValues) {
      final page = _pages[_pageKey(kind, category)];
      if (page != null &&
          page.items.any((item) => _mediaIdentity(item.url) == id)) {
        yield category;
      }
    }
  }

  LibraryCategory? _trackedCategoryForMutation(
    String url,
    LibraryMediaKind kind,
  ) =>
      _localItemCategory(url) ?? _loadedNativeCategories(url, kind).firstOrNull;

  MultimediaItem? _findLocalItemByUrl(
    LibraryMediaKind kind,
    LibraryCategory category,
    String url,
  ) {
    final id = _mediaIdentity(url);
    for (final item in _localItems(kind, category)) {
      if (_mediaIdentity(item.url) == id) return item;
    }
    return null;
  }

  void _adjustCategoryCount(
    LibraryMediaKind kind,
    LibraryCategory category,
    int delta,
  ) {
    if (delta == 0) return;
    final key = _countsKey(kind);
    if (_countRequests.containsKey(key)) {
      final deltas = _inFlightCountDeltas.putIfAbsent(
        key,
        () => <LibraryCategory, int>{},
      );
      deltas[category] = (deltas[category] ?? 0) + delta;
    }
    final page = _page(kind, category);
    final known = _knownTotal(kind, category);
    if (known != null) {
      final next = (known + delta).clamp(0, 1 << 30);
      page.total = next;
      _confirmedCounts[key]?[category] = next;
      unawaited(_saveCachedCategoryCounts(kind, {category: next}));
    } else {
      final cached = _cachedCategoryCount(kind, category);
      if (cached != null) {
        unawaited(
          _saveCachedCategoryCounts(kind, {
            category: (cached + delta).clamp(0, 1 << 30),
          }),
        );
      }
    }
    _countRevision++;
  }

  void _addLocalItemToShelf(
    LibraryMediaKind kind,
    LibraryCategory category,
    MultimediaItem item,
  ) {
    final page = _page(kind, category);
    final id = _mediaIdentity(item.url);
    final hadItem = page.items.any((row) => _mediaIdentity(row.url) == id);
    page.mutationVersion++;
    page.items.removeWhere((row) => _mediaIdentity(row.url) == id);
    page.items.insert(0, item);
    if (page.receivedRemotePage &&
        !hadItem &&
        page.items.length > page.visibleLimit) {
      page.visibleLimit = page.items.length;
    }
    if (!hadItem) _adjustCategoryCount(kind, category, 1);
  }

  void _removeLocalItemFromShelf(
    LibraryMediaKind kind,
    LibraryCategory category,
    String url,
  ) {
    final page = _page(kind, category);
    final id = _mediaIdentity(url);
    page.mutationVersion++;
    page.items.removeWhere((row) => _mediaIdentity(row.url) == id);
    _adjustCategoryCount(kind, category, -1);
  }

  void _upsertLocalItemInShelf(
    LibraryMediaKind kind,
    LibraryCategory category,
    MultimediaItem item,
  ) {
    final page = _page(kind, category);
    final id = _mediaIdentity(item.url);
    final index = page.items.indexWhere((row) => _mediaIdentity(row.url) == id);
    if (index >= 0) page.items[index] = item;
  }

  Future<void> addItem(
    MultimediaItem item, {
    LibraryCategory? category,
    LibraryMembership? membership,
  }) async {
    final selected = category ?? state.category;
    if (selected == LibraryCategory.favorite) {
      await setFavorite(item, true, membership: membership);
      return;
    }
    _requireSignedIn();
    final kind = item.contentType == MultimediaContentType.manga
        ? LibraryMediaKind.manga
        : LibraryMediaKind.anime;
    var tracked =
        _trackedCategoryForMutation(item.url, kind) ?? membership?.category;
    void syncLocal() {
      final current = _localItemCategory(item.url);
      if (current != tracked) {
        if (tracked != null) {
          _removeLocalItemFromShelf(kind, tracked!, item.url);
        }
        if (current != null) {
          _addLocalItemToShelf(
            kind,
            current,
            _findLocalItemByUrl(kind, current, item.url) ?? item,
          );
        }
        tracked = current;
      } else if (current != null) {
        _upsertLocalItemInShelf(
          kind,
          current,
          _findLocalItemByUrl(kind, current, item.url) ?? item,
        );
      }
    }

    await ref
        .read(libraryRepositoryProvider)
        .addToLibrary(
          item,
          category: selected,
          membership: membership,
          onLocalChanged: () {
            syncLocal();
            refresh();
          },
        );
    syncLocal();
    refresh();
  }

  Future<void> clearItemCategory(
    String url, {
    bool manga = false,
    String? providerId,
    LibraryCategory? previousCategory,
  }) async {
    _requireSignedIn();
    final kind = manga ? LibraryMediaKind.manga : LibraryMediaKind.anime;
    var tracked = _trackedCategoryForMutation(url, kind) ?? previousCategory;
    void syncLocal() {
      final current = _localItemCategory(url);
      if (current != tracked) {
        if (tracked != null) {
          _removeLocalItemFromShelf(kind, tracked!, url);
        }
        if (current != null) {
          final restored = _findLocalItemByUrl(kind, current, url);
          if (restored != null) _addLocalItemToShelf(kind, current, restored);
        }
        tracked = current;
      }
      if (current == null) {
        for (final cached in _loadedNativeCategories(url, kind).toList()) {
          if (cached != tracked) {
            _removeLocalItemFromShelf(kind, cached, url);
          }
        }
      }
    }

    await ref
        .read(libraryRepositoryProvider)
        .clearCategory(
          url,
          manga: manga,
          onLocalChanged: () {
            syncLocal();
            refresh();
          },
        );
    syncLocal();
    refresh();
  }

  Future<void> setFavorite(
    MultimediaItem item,
    bool favorite, {
    LibraryMembership? membership,
  }) async {
    _requireSignedIn();
    final kind = item.contentType == MultimediaContentType.manga
        ? LibraryMediaKind.manga
        : LibraryMediaKind.anime;
    var trackedFavorite = membership?.favorite ?? isFavorite(item.url);
    void syncLocal() {
      final current = isFavorite(item.url);
      if (current == trackedFavorite) return;
      if (current) {
        _addLocalItemToShelf(
          kind,
          LibraryCategory.favorite,
          _findLocalItemByUrl(kind, LibraryCategory.favorite, item.url) ?? item,
        );
      } else {
        _removeLocalItemFromShelf(kind, LibraryCategory.favorite, item.url);
      }
      trackedFavorite = current;
    }

    await ref
        .read(libraryRepositoryProvider)
        .setFavorite(
          item,
          favorite,
          membership: membership,
          onLocalChanged: () {
            syncLocal();
            refresh();
          },
        );
    syncLocal();
    refresh();
  }

  void _requireSignedIn() {
    requireLibrarySignIn(
      ref.read(animeWitcherAccountServiceProvider).isSignedIn,
    );
  }

  bool isFavorite(String url, {String? providerId}) =>
      ref.read(libraryRepositoryProvider).isFavorite(url);

  LibraryCategory? itemCategory(
    String url, {
    String? providerId,
    bool manga = false,
  }) => _trackedCategoryForMutation(
    url,
    manga ? LibraryMediaKind.manga : LibraryMediaKind.anime,
  );

  LibraryCategory? _localItemCategory(String url) =>
      ref.read(libraryRepositoryProvider).getItemCategory(url);
}
