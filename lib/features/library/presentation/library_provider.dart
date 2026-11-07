import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/storage/library_category.dart';
import '../../../../core/storage/library_repository.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/storage/provider_local_library.dart';
import '../../../../core/storage/anime_rift_auto_sync.dart';
import '../../../../core/storage/anime_rift_account_scope.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/providers/anime_rift_provider.dart';
import '../../../../core/services/app_diagnostics.dart';

import './library_auth.dart';
import './library_state.dart';
import './library_media_kind.dart';

part 'library_provider.g.dart';

/// Server-reported library count is separate from the number loaded so far.
/// An unknown server total must never be advertised as a confirmed zero.
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
  int visibleLimit = 30;
  int cachedLocalCount = 0;
  int? total;
  bool loading = false;
  bool loadFailed = false;
  bool hasMore = false;
  bool receivedRemotePage = false;
  AnimeWitcherLibraryCursor? nativeCursor;
  final List<MultimediaItem> nativeItems = [];
}

@Riverpod(keepAlive: true)
class Library extends _$Library {
  static const _riftAnimeCategoryKey = 'animerift_library_anime_category';
  static const pageSize = 30;
  final _pages = <String, _LibraryShelfCursorState>{};
  final _confirmedCounts = <String, Map<LibraryCategory, int>>{};
  final _countRequests = <String, Future<void>>{};
  ProviderLocalLibrary? _riftLocalLibrary;
  String? _riftLocalOwner;
  int _countRevision = 0;
  int get countRevision => _countRevision;
  int _selectionGeneration = 0;

  String _countsKey(LibraryMediaKind kind) =>
      '${_pageKey(kind, LibraryCategory.watching)}:counts';

  /// Fetch totals without fetching poster rows. An unknown total is not zero.
  Future<void> refreshServerCounts(LibraryMediaKind kind) {
    final key = _countsKey(kind);
    if (_confirmedCounts.containsKey(key)) return Future<void>.value();
    final active = _countRequests[key];
    if (active != null) return active;
    final provider = ref.read(activeProviderProvider);
    final isRift =
        kind == LibraryMediaKind.anime && provider is AnimeRiftProvider;
    final service = ref.read(animeWitcherAccountServiceProvider);
    if (isRift
        ? AnimeRiftLocalAccountScope.accountHash == null
        : !service.isSignedIn) {
      return Future<void>.value();
    }
    final request = () async {
      try {
        final Map<LibraryCategory, int> counts;
        if (isRift) {
          final overview = await provider.fetchCloudLibraryCounts();
          const keys = <LibraryCategory, String>{
            LibraryCategory.favorite: 'my_list_favorites',
            LibraryCategory.watching: 'my_list_currently_watching',
            LibraryCategory.planToWatch: 'my_list_plan_to_watch',
            LibraryCategory.completed: 'my_list_finished_watching',
            LibraryCategory.continueLater: 'my_list_on_hold',
            LibraryCategory.notInterested: 'my_list_dropped',
          };
          counts = {
            for (final entry in keys.entries)
              if (overview[entry.value] case final int total) entry.key: total,
          };
        } else {
          counts = await service.fetchLibraryCounts(
            manga: kind == LibraryMediaKind.manga,
          );
        }
        if (ref.mounted && _countsKey(kind) == key) {
          _confirmedCounts[key] = counts;
          _countRevision++;
          refresh();
        }
      } catch (_) {
        // Retry on the next library visit or account restoration.
      }
    }();
    _countRequests[key] = request;
    return request.whenComplete(() {
      _countRequests.remove(key);
    });
  }

  String _pageKey(LibraryMediaKind kind, LibraryCategory category) {
    final isRift =
        ref.read(activeProviderProvider)?.packageName == animeRiftProviderId &&
        kind == LibraryMediaKind.anime;
    final owner = isRift
        ? AnimeRiftLocalAccountScope.accountHash
        : ref.read(animeWitcherAccountServiceProvider).accountUid;
    return '${isRift ? animeRiftProviderId : 'native'}:${owner ?? 'guest'}:'
        '${kind.storageKey}:${category.storageKey}';
  }

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
  ) {
    final isRift =
        ref.read(activeProviderProvider)?.packageName == animeRiftProviderId &&
        kind == LibraryMediaKind.anime;
    return filterLibraryItemsByKind(
      isRift
          ? _local().items(category)
          : ref
                .read(libraryRepositoryProvider)
                .getLibraryItems(category: category),
      kind,
    );
  }

  List<MultimediaItem> _visibleItems(
    LibraryMediaKind kind,
    LibraryCategory category,
  ) {
    final page = _page(kind, category);
    final local = _localItems(kind, category);
    page.cachedLocalCount = local.length;
    final provider = ref.read(activeProviderProvider);
    if (kind == LibraryMediaKind.anime &&
        provider is AnimeRiftProvider &&
        page.receivedRemotePage) {
      final urls = provider.cloudLibraryItemUrls(category);
      if (urls != null) {
        final localByUrl = {for (final item in local) item.url: item};
        return [
          for (final url in urls.take(page.visibleLimit))
            if (localByUrl[url] case final item?) item,
        ];
      }
    }
    final isNativeRemote =
        page.receivedRemotePage &&
        !(kind == LibraryMediaKind.anime &&
            ref.read(activeProviderProvider)?.packageName ==
                animeRiftProviderId);
    // A native page is ordered by Firestore; an old local cache may contain
    // hundreds of rows and must not silently reveal the whole server shelf.
    final rows = isNativeRemote && page.nativeItems.isNotEmpty
        ? page.nativeItems
        : local;
    return rows.take(page.visibleLimit).toList(growable: false);
  }

  LibraryShelfPageInfo pageInfo(
    LibraryMediaKind kind,
    LibraryCategory category, {
    int? loadedLocalCount,
  }) {
    final page = _page(kind, category);
    final localCount = loadedLocalCount ?? page.cachedLocalCount;
    final total = _knownTotal(kind, category);
    final count =
        page.receivedRemotePage &&
            !(kind == LibraryMediaKind.anime &&
                ref.read(activeProviderProvider)?.packageName ==
                    animeRiftProviderId)
        ? page.nativeItems.length
        : localCount;
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
    final provider = ref.read(activeProviderProvider);
    final rift =
        kind == LibraryMediaKind.anime &&
        provider?.packageName == animeRiftProviderId;
    final confirmed = _knownTotal(kind, category);
    if (confirmed != null) return confirmed;
    final linked = rift
        ? AnimeRiftLocalAccountScope.accountHash != null
        : ref.read(animeWitcherAccountServiceProvider).isSignedIn;
    // While fetching overview/Firestore counts, don't turn unknown into zero.
    if (linked) return null;
    return _localItems(kind, category).length;
  }

  int? _knownTotal(LibraryMediaKind kind, LibraryCategory category) {
    final provider = ref.read(activeProviderProvider);
    return _page(kind, category).total ??
        _confirmedCounts[_countsKey(kind)]?[category] ??
        (kind == LibraryMediaKind.anime && provider is AnimeRiftProvider
            ? provider.cloudLibraryTotal(category)
            : null);
  }

  @override
  LibraryState build() {
    ++_selectionGeneration;
    ref.watch(accountDataRevisionProvider);
    ref.watch(activeProviderProvider);
    final mediaKind = LibraryMediaKind.fromStorageKey(
      ref.read(storageServiceProvider).getString('library_media_kind'),
    );
    final category = _categoryFor(mediaKind);
    final items = _visibleItems(mediaKind, category);
    Future<void>.microtask(() {
      if (!ref.mounted) return;
      for (final kind in LibraryMediaKind.values) {
        unawaited(refreshServerCounts(kind));
      }
    });
    return items.isEmpty
        ? LibraryEmpty(category, mediaKind)
        : LibrarySuccess(items, category, mediaKind);
  }

  List<MultimediaItem> itemsForCategory(
    LibraryMediaKind kind,
    LibraryCategory category,
  ) {
    return _visibleItems(kind, category);
  }

  LibraryCategory get selectedCategory => state.category;
  LibraryMediaKind get selectedMediaKind => state.mediaKind;

  LibraryState refresh({
    LibraryCategory? category,
    LibraryMediaKind? mediaKind,
  }) {
    final selected = category ?? state.category;
    final selectedKind = mediaKind ?? state.mediaKind;
    final items = _visibleItems(selectedKind, selected);
    state = items.isEmpty
        ? LibraryEmpty(selected, selectedKind)
        : LibrarySuccess(items, selected, selectedKind);
    return state;
  }

  /// Display fetches exactly one 30-row server page, never the whole library.
  /// Cached rows remain visible offline; a partial response never deletes any
  /// cached item nor resolves missing remote rows as server-side deletions.
  Future<void> refreshVisibleFromServer({
    LibraryCategory? category,
    LibraryMediaKind? mediaKind,
  }) async {
    final kind = mediaKind ?? state.mediaKind;
    final shelf = category ?? state.category;
    final page = _page(kind, shelf);
    if (page.loading) return;
    final providerId = ref.read(activeProviderProvider)?.packageName;
    final isRift =
        providerId == animeRiftProviderId && kind == LibraryMediaKind.anime;
    final service = ref.read(animeWitcherAccountServiceProvider);
    final account = isRift
        ? AnimeRiftLocalAccountScope.accountHash
        : service.accountUid;
    if (account == null) return;
    page.loading = true;
    page.loadFailed = false;
    refresh();
    final elapsed = Stopwatch()..start();
    final pageKey = _pageKey(kind, shelf);
    try {
      if (isRift) {
        await ref
            .read(riftAutoSyncProvider)
            .refreshCategory(shelf)
            .timeout(const Duration(seconds: 25));
        final provider = ref.read(activeProviderProvider);
        final remote = provider is AnimeRiftProvider
            ? provider.cloudLibraryPage(shelf)
            : null;
        if (remote != null && _pageKey(kind, shelf) == pageKey) {
          page.total = remote.totalCount;
          page.visibleLimit = remote.loadedCount.clamp(pageSize, 20000);
          page.hasMore = remote.hasMore;
          page.receivedRemotePage = true;
        }
      } else {
        final result = await service
            .fetchLibraryPage(
              category: shelf,
              manga: kind == LibraryMediaKind.manga,
            )
            .timeout(const Duration(seconds: 25));
        if (_pageKey(kind, shelf) == pageKey) {
          page.nativeItems
            ..clear()
            ..addAll(result.items);
          page.nativeCursor = result.nextCursor;
          page.total = result.total;
          page.hasMore = result.hasMore;
          page.visibleLimit = pageSize;
          page.receivedRemotePage = true;
        }
      }
      if (!ref.mounted ||
          providerId != ref.read(activeProviderProvider)?.packageName ||
          account !=
              (isRift
                  ? AnimeRiftLocalAccountScope.accountHash
                  : service.accountUid)) {
        return;
      }
      // The import has already persisted the new cache. Notify all shelf
      // views, including counts and the phone's sorted in-memory list cache.
      refresh();
    } catch (error) {
      page.loadFailed = true;
      appDiagnostics.record('library.page', {
        'action': 'first',
        'status': error is TimeoutException ? 'timeout' : 'failed',
        'reason': isRift ? 'rift' : 'native',
        'durationMs': elapsed.elapsedMilliseconds,
        'retryable': true,
      });
      // Keep cached items visible; show a retry instead of an endless spinner.
    } finally {
      page.loading = false;
      if (!page.loadFailed) {
        appDiagnostics.record('library.page', {
          'action': 'first',
          'status': 'ok',
          'reason': isRift ? 'rift' : 'native',
          'durationMs': elapsed.elapsedMilliseconds,
          'count': page.visibleLimit,
        });
      }
      if (ref.mounted) refresh();
    }
  }

  /// Invoked from the bottom of a library grid. Concurrent scroll triggers
  /// coalesce and the cursor is tied to provider, account and category.
  Future<void> loadNextPage({
    required LibraryMediaKind mediaKind,
    required LibraryCategory category,
  }) async {
    final page = _page(mediaKind, category);
    if (page.loading) return;
    final key = _pageKey(mediaKind, category);
    final isRift =
        ref.read(activeProviderProvider)?.packageName == animeRiftProviderId &&
        mediaKind == LibraryMediaKind.anime;
    final service = ref.read(animeWitcherAccountServiceProvider);
    final account = isRift
        ? AnimeRiftLocalAccountScope.accountHash
        : service.accountUid;
    if (account == null) {
      page.visibleLimit += pageSize;
      refresh();
      return;
    }
    if (!page.receivedRemotePage) {
      await refreshVisibleFromServer(category: category, mediaKind: mediaKind);
      return;
    }
    final total = _knownTotal(mediaKind, category);
    final loaded = isRift ? page.visibleLimit : page.nativeItems.length;
    if (total != null && loaded >= total) {
      page.hasMore = false;
      return;
    }
    if (!page.hasMore) return;
    page.loading = true;
    page.loadFailed = false;
    refresh();
    final elapsed = Stopwatch()..start();
    try {
      if (isRift) {
        final provider = ref.read(activeProviderProvider);
        if (provider is! AnimeRiftProvider) return;
        await provider
            .importCloudLibraryCategory(
              ref.read(storageServiceProvider),
              category,
              loadNextPage: true,
            )
            .timeout(const Duration(seconds: 25));
        if (ref.mounted && _pageKey(mediaKind, category) == key) {
          final remote = provider.cloudLibraryPage(category);
          if (remote != null) {
            page.visibleLimit = remote.loadedCount.clamp(pageSize, 20000);
            page.total = remote.totalCount;
            page.hasMore = remote.hasMore;
          }
        }
      } else {
        final cursor = page.nativeCursor;
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
        if (ref.mounted && _pageKey(mediaKind, category) == key) {
          final seen = page.nativeItems.map((item) => item.url).toSet();
          for (final item in result.items) {
            if (seen.add(item.url)) page.nativeItems.add(item);
          }
          page.nativeCursor = result.nextCursor;
          page.total = result.total;
          page.hasMore = result.hasMore;
          page.visibleLimit = page.nativeItems.length;
        }
      }
    } catch (error) {
      page.loadFailed = true;
      appDiagnostics.record('library.page', {
        'action': 'next',
        'status': error is TimeoutException ? 'timeout' : 'failed',
        'reason': isRift ? 'rift' : 'native',
        'durationMs': elapsed.elapsedMilliseconds,
        'retryable': true,
      });
      // A failed next page preserves the cursor for the retry control.
    } finally {
      page.loading = false;
      if (!page.loadFailed) {
        appDiagnostics.record('library.page', {
          'action': 'next',
          'status': 'ok',
          'reason': isRift ? 'rift' : 'native',
          'durationMs': elapsed.elapsedMilliseconds,
          'count': page.visibleLimit,
        });
      }
      if (ref.mounted) refresh();
    }
  }

  Future<void> selectCategory(LibraryCategory category) async {
    final generation = ++_selectionGeneration;
    final kind = state.mediaKind;
    final providerId = ref.read(activeProviderProvider)?.packageName;
    await _saveCategory(kind, category, providerId);
    if (ref.mounted &&
        generation == _selectionGeneration &&
        ref.read(activeProviderProvider)?.packageName == providerId) {
      refresh(category: category);
      unawaited(refreshVisibleFromServer(category: category, mediaKind: kind));
    }
  }

  /// Picks [category] of the [mediaKind] half at once, as the side list does.
  Future<void> select(
    LibraryMediaKind mediaKind,
    LibraryCategory category,
  ) async {
    final generation = ++_selectionGeneration;
    final providerId = ref.read(activeProviderProvider)?.packageName;
    await ref
        .read(storageServiceProvider)
        .setString('library_media_kind', mediaKind.storageKey);
    await _saveCategory(mediaKind, category, providerId);
    if (ref.mounted &&
        generation == _selectionGeneration &&
        ref.read(activeProviderProvider)?.packageName == providerId) {
      refresh(category: category, mediaKind: mediaKind);
      unawaited(
        refreshVisibleFromServer(category: category, mediaKind: mediaKind),
      );
    }
  }

  Future<void> selectMediaKind(LibraryMediaKind mediaKind) async {
    final generation = ++_selectionGeneration;
    final providerId = ref.read(activeProviderProvider)?.packageName;
    await ref
        .read(storageServiceProvider)
        .setString('library_media_kind', mediaKind.storageKey);
    if (ref.mounted &&
        generation == _selectionGeneration &&
        ref.read(activeProviderProvider)?.packageName == providerId) {
      refresh(category: _categoryFor(mediaKind), mediaKind: mediaKind);
      unawaited(
        refreshVisibleFromServer(
          category: state.category,
          mediaKind: mediaKind,
        ),
      );
    }
  }

  bool _isRiftAnime(LibraryMediaKind kind) =>
      kind == LibraryMediaKind.anime &&
      ref.read(activeProviderProvider)?.packageName == animeRiftProviderId;

  LibraryCategory _categoryFor(LibraryMediaKind kind) {
    if (_isRiftAnime(kind)) {
      final rift = ref
          .read(storageServiceProvider)
          .getString(_riftAnimeCategoryKey);
      return LibraryCategory.fromStorageKey(
        rift ?? LibraryCategory.watching.storageKey,
      );
    }
    return ref.read(libraryRepositoryProvider).getSelectedCategory();
  }

  Future<void> _saveCategory(
    LibraryMediaKind kind,
    LibraryCategory category,
    String? providerId,
  ) async {
    if (kind == LibraryMediaKind.anime && providerId == animeRiftProviderId) {
      await ref
          .read(storageServiceProvider)
          .setString(_riftAnimeCategoryKey, category.storageKey);
    } else {
      await ref.read(libraryRepositoryProvider).setSelectedCategory(category);
    }
  }

  Future<void> addItem(MultimediaItem item, {LibraryCategory? category}) async {
    if (item.provider == animeRiftProviderId &&
        item.contentType != MultimediaContentType.manga) {
      final selected = category ?? state.category;
      if (selected != LibraryCategory.favorite &&
          !selected.isAssignableTo(item)) {
        return;
      }
      if (selected == LibraryCategory.favorite) {
        await _local().setFavorite(item, true);
        await ref.read(riftAutoSyncProvider).queueFavorite(item.url, true);
      } else {
        await _local().setCategory(item, selected);
        await ref.read(riftAutoSyncProvider).queueCategory(item.url, selected);
      }
      refresh();
      return;
    }
    _requireSignedIn();
    final repository = ref.read(libraryRepositoryProvider);
    await repository.addToLibrary(
      item,
      category: category ?? state.category,
      onLocalChanged: refresh,
    );
    refresh();
  }

  Future<void> clearItemCategory(
    String url, {
    bool manga = false,
    String? providerId,
  }) async {
    if (!manga && providerId == animeRiftProviderId) {
      await _local().clearCategory(url);
      await ref.read(riftAutoSyncProvider).queueCategory(url, null);
      refresh();
      return;
    }
    _requireSignedIn();
    final repository = ref.read(libraryRepositoryProvider);
    await repository.clearCategory(url, onLocalChanged: refresh);
    refresh();
  }

  Future<void> setFavorite(MultimediaItem item, bool favorite) async {
    if (item.provider == animeRiftProviderId &&
        item.contentType != MultimediaContentType.manga) {
      await _local().setFavorite(item, favorite);
      await ref.read(riftAutoSyncProvider).queueFavorite(item.url, favorite);
      refresh();
      return;
    }
    _requireSignedIn();
    final repository = ref.read(libraryRepositoryProvider);
    await repository.setFavorite(item, favorite, onLocalChanged: refresh);
    refresh();
  }

  void _requireSignedIn() {
    requireLibrarySignIn(
      ref.read(animeWitcherAccountServiceProvider).isSignedIn,
    );
  }

  ProviderLocalLibrary _local() {
    final owner = AnimeRiftLocalAccountScope.accountHash;
    if (_riftLocalLibrary == null || _riftLocalOwner != owner) {
      _riftLocalOwner = owner;
      _riftLocalLibrary = ProviderLocalLibrary(
        ref.read(storageServiceProvider),
        animeRiftProviderId,
      );
    }
    return _riftLocalLibrary!;
  }

  bool isFavorite(String url, {String? providerId}) {
    if (providerId == animeRiftProviderId) return _local().isFavorite(url);
    final repository = ref.read(libraryRepositoryProvider);
    return repository.isFavorite(url);
  }

  LibraryCategory? itemCategory(String url, {String? providerId}) {
    if (providerId == animeRiftProviderId) return _local().category(url);
    final repository = ref.read(libraryRepositoryProvider);
    return repository.getItemCategory(url);
  }
}
