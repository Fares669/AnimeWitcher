import 'dart:async';
import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/account/account_providers.dart';
import '../../../../core/account/animewitcher_comment_models.dart'
    show animeWitcherNativeProviderId;
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/domain/entity/manga.dart';
import '../../../../core/extensions/base_provider.dart';

import './home_state.dart';

part 'home_provider.g.dart';

@Riverpod(keepAlive: true)
class HomeData extends _$HomeData {
  int _fetchGeneration = 0;
  // Account restoration can emit several revisions without changing the
  // public Home feed. This window is shorter than the regular account sync
  // cadence so it doesn't turn off the occasional background refresh.
  static const _accountRevisionCoalescingWindow = Duration(seconds: 30);
  final _nativeLoadAge = Stopwatch();
  (AnimeWitcherNativeProvider, AnimeWitcherProvider?, bool)? _nativeDemand;

  AnimeWitcherProvider? _readMangaProvider() {
    final mangaProviders = ref
        .read(extensionManagerProvider)
        .where(
          (provider) => provider.supportedTypes.contains(ProviderType.manga),
        );
    return mangaProviders
            .where(
              (provider) =>
                  provider.packageName == animeWitcherNativeProviderId,
            )
            .firstOrNull ??
        mangaProviders.firstOrNull;
  }

  (AnimeWitcherNativeProvider, AnimeWitcherProvider?, bool)? _demandFor(
    AnimeWitcherProvider? anime,
    AnimeWitcherProvider? manga,
  ) {
    // Only the built-in public catalogue has these account dependencies.
    // Other providers keep their existing refresh behavior.
    if (anime is! AnimeWitcherNativeProvider ||
        (manga != null && manga is! AnimeWitcherNativeProvider)) {
      return null;
    }
    return (anime, manga, anime.hidesEcchiInDiscovery);
  }

  @override
  HomeState build() {
    // Account sync (including the 1-minute foreground refresh) must not
    // tear down a loaded home page. Refetch in the background instead.
    ref.listen<int>(accountDataRevisionProvider, (previous, next) {
      if (previous == next) return;
      final active = ref.read(activeProviderProvider);
      if (active == null) return;
      final manga = _readMangaProvider();
      if (_nativeDemand != null &&
          _nativeLoadAge.elapsed < _accountRevisionCoalescingWindow &&
          _nativeDemand == _demandFor(active, manga)) {
        // Account-owned rows, e.g. Continue Watching, observe the revision
        // independently. Don't restart an equivalent public catalogue load.
        return;
      }
      unawaited(_fetch(active, manga, keepCurrent: true));
    });

    ref.listen<AnimeWitcherProvider?>(activeProviderProvider, (previous, next) {
      if (previous?.packageName == next?.packageName) return;
      if (next == null) {
        ++_fetchGeneration;
        _nativeDemand = null;
        state = const HomeNoProvider();
        return;
      }
      unawaited(fetch());
    });

    final activeProvider = ref.read(activeProviderProvider);
    if (activeProvider == null) {
      return const HomeNoProvider();
    }

    Future.microtask(() => fetch(keepCurrent: true));
    // Last launch's rows, shown at once while the catalogue is asked again:
    // the request takes seconds, and the rows rarely change in between.
    final kept = _readSnapshot(activeProvider.packageName);
    return kept == null ? const HomeLoading() : HomeSuccess(kept);
  }

  static String _snapshotKey(String packageName) =>
      'home_snapshot_$packageName';

  Map<String, List<MultimediaItem>>? _readSnapshot(String packageName) {
    try {
      final raw = ref
          .read(storageServiceProvider)
          .getString(_snapshotKey(packageName));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      final rows = decoded is Map ? decoded['rows'] : null;
      if (rows is! Map || rows.isEmpty) return null;
      return <String, List<MultimediaItem>>{
        for (final entry in rows.entries)
          if (entry.value is List)
            '${entry.key}': <MultimediaItem>[
              for (final item in entry.value as List)
                if (item is Map)
                  MultimediaItem.fromJson(Map<String, dynamic>.from(item)),
            ],
      };
    } catch (_) {
      // An unreadable snapshot only costs the instant start.
      return null;
    }
  }

  void _saveSnapshot(
    String packageName,
    Map<String, List<MultimediaItem>> rows,
  ) {
    if (rows.isEmpty) return;
    try {
      final encoded = jsonEncode(<String, dynamic>{
        'rows': <String, dynamic>{
          for (final entry in rows.entries)
            entry.key: entry.value.map((item) => item.toJson()).toList(),
        },
      });
      unawaited(
        ref
            .read(storageServiceProvider)
            .setString(_snapshotKey(packageName), encoded)
            .catchError((_) {}),
      );
    } catch (_) {}
  }

  /// Retry after an offline/error screen. Drops stale HTTP sockets first so
  /// the following request is not served from a dead connection pool.
  Future<void> retry() async {
    ref.read(activeProviderProvider)?.prepareForNetworkRetry();
    await fetch();
  }

  /// Loads home sections.
  ///
  /// When [keepCurrent] is true and the page already has data, the visible
  /// lists stay on screen while the request runs. Pull-to-refresh, tab
  /// return, and account sync use that path so the home page does not flash
  /// its loading shimmer.
  Future<void> fetch({bool keepCurrent = false}) async {
    final active = ref.read(activeProviderProvider);
    return _fetch(
      active,
      active == null ? null : _readMangaProvider(),
      keepCurrent: keepCurrent,
    );
  }

  Future<void> _fetch(
    AnimeWitcherProvider? activeProvider,
    AnimeWitcherProvider? mangaProvider, {
    required bool keepCurrent,
  }) async {
    final generation = ++_fetchGeneration;
    final previous = keepCurrent && state is HomeSuccess
        ? state as HomeSuccess
        : null;
    final preserveCurrent = previous != null;
    if (!preserveCurrent) {
      state = const HomeLoading();
    }

    _nativeDemand = _demandFor(activeProvider, mangaProvider);
    if (activeProvider == null) {
      if (!ref.mounted || generation != _fetchGeneration) return;
      state = const HomeNoProvider();
      return;
    }

    if (_nativeDemand != null) {
      _nativeLoadAge
        ..reset()
        ..start();
    }

    // News and the new manga chapters are asked for alongside the anime
    // rows, but the page does not wait for them: it shows as soon as its own
    // rows are in, and the other two join it when they land. Held back, the
    // page opened only when the slowest of the three answered.
    final news = _orNull(() => activeProvider.getHomeNewsPage(limit: 10));
    final manga = mangaProvider == null
        ? Future<MangaLatestChapterPage?>.value(null)
        : _orNull(() => mangaProvider.getLatestMangaPage(limit: 20));
    MangaLatestChapterPage? mangaPage;
    // Manga may arrive before or after the anime home request.
    unawaited(
      manga.then((page) {
        if (!ref.mounted || page == null || generation != _fetchGeneration) {
          return;
        }
        mangaPage = page;
        final current = state;
        if (current is HomeSuccess) {
          state = HomeSuccess(
            current.data,
            news: current.news,
            latestManga: page.items,
          );
        }
      }),
    );

    try {
      final items = await activeProvider.getHome();
      if (!ref.mounted || generation != _fetchGeneration) return;
      _saveSnapshot(activeProvider.packageName, items);
      state = HomeSuccess(
        items,
        news: previous?.news ?? const <NewsItem>[],
        latestManga:
            mangaPage?.items ??
            previous?.latestManga ??
            const <MangaLatestChapter>[],
      );
    } catch (e) {
      if (!ref.mounted || generation != _fetchGeneration) return;
      _nativeDemand = null;
      if (preserveCurrent) return;
      state = HomeError(e.toString());
      return;
    }

    // A failed side request keeps what the page already shows.
    unawaited(
      news.then((page) {
        if (!ref.mounted || generation != _fetchGeneration || page == null) {
          return;
        }
        final current = state;
        if (current is! HomeSuccess) return;
        state = HomeSuccess(
          current.data,
          news: page.items,
          latestManga: current.latestManga,
        );
      }),
    );
  }

  static Future<T?> _orNull<T>(Future<T> Function() request) async {
    try {
      return await request();
    } catch (_) {
      return null;
    }
  }
}

@riverpod
class HomeFilter extends _$HomeFilter {
  @override
  ProviderType? build() {
    final storage = ref.read(storageServiceProvider);
    final saved = storage.getHomeCategory();
    if (saved != null) {
      try {
        return ProviderType.values.firstWhere((e) => e.name == saved);
      } catch (_) {}
    }
    return null;
  }

  Future<void> setFilter(ProviderType? type) async {
    state = type;
    final storage = ref.read(storageServiceProvider);
    await storage.setHomeCategory(type?.name);
  }
}
