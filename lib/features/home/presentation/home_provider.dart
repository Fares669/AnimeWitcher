import 'dart:async';
import 'dart:convert';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/account/account_providers.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/domain/entity/manga.dart';
import '../../../../core/extensions/base_provider.dart';

import './home_state.dart';

part 'home_provider.g.dart';

@Riverpod(keepAlive: true)
class HomeData extends _$HomeData {
  int _fetchGeneration = 0;

  @override
  HomeState build() {
    // Account sync (including the 1-minute foreground refresh) must not
    // tear down a loaded home page. Refetch in the background instead.
    ref.listen<int>(accountDataRevisionProvider, (previous, next) {
      if (previous == next) return;
      unawaited(fetch(keepCurrent: true));
    });

    ref.listen<AnimeWitcherProvider?>(activeProviderProvider, (previous, next) {
      if (previous?.packageName == next?.packageName) return;
      if (next == null) {
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
    final generation = ++_fetchGeneration;
    final preserveCurrent = keepCurrent && state is HomeSuccess;
    if (!preserveCurrent) {
      state = const HomeLoading();
    }

    final activeProvider = ref.read(activeProviderProvider);
    if (activeProvider == null) {
      if (generation != _fetchGeneration) return;
      state = const HomeNoProvider();
      return;
    }

    // News and the new manga chapters are asked for alongside the anime
    // rows, but the page does not wait for them: it shows as soon as its own
    // rows are in, and the other two join it when they land. Held back, the
    // page opened only when the slowest of the three answered.
    final news = _orNull(() => activeProvider.getHomeNewsPage(limit: 10));
    final manga = _orNull(() => activeProvider.getLatestMangaPage(limit: 20));
    final previous = state is HomeSuccess ? state as HomeSuccess : null;

    try {
      final items = await activeProvider.getHome();
      if (generation != _fetchGeneration) return;
      _saveSnapshot(activeProvider.packageName, items);
      state = HomeSuccess(
        items,
        news: previous?.news ?? const <NewsItem>[],
        latestManga: previous?.latestManga ?? const <MangaLatestChapter>[],
      );
    } catch (e) {
      if (generation != _fetchGeneration) return;
      if (preserveCurrent) return;
      state = HomeError(e.toString());
      return;
    }

    // A failed side request keeps what the page already shows.
    unawaited(
      news.then((page) {
        final current = state;
        if (page == null ||
            generation != _fetchGeneration ||
            current is! HomeSuccess) {
          return;
        }
        state = HomeSuccess(
          current.data,
          news: page.items,
          latestManga: current.latestManga,
        );
      }),
    );
    unawaited(
      manga.then((page) {
        final current = state;
        if (page == null ||
            generation != _fetchGeneration ||
            current is! HomeSuccess) {
          return;
        }
        state = HomeSuccess(
          current.data,
          news: current.news,
          latestManga: page.items,
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
