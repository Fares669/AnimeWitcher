import 'dart:async';

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
    return const HomeLoading();
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

    try {
      final results = await Future.wait<dynamic>([
        activeProvider.getHome(),
        () async {
          try {
            return await activeProvider.getHomeNewsPage(limit: 10);
          } catch (_) {
            return const ProviderNewsPage(
              items: <NewsItem>[],
              nextOffset: 0,
              hasMore: false,
            );
          }
        }(),
        () async {
          try {
            return await activeProvider.getLatestMangaPage(limit: 20);
          } catch (_) {
            return const MangaLatestChapterPage(
              items: <MangaLatestChapter>[],
              nextOffset: 0,
              hasMore: false,
            );
          }
        }(),
      ]);
      if (generation != _fetchGeneration) return;
      final items = results[0] as Map<String, List<MultimediaItem>>;
      final newsPage = results[1] as ProviderNewsPage;
      final latestManga = results[2] as MangaLatestChapterPage;
      state = HomeSuccess(
        items,
        news: newsPage.items,
        latestManga: latestManga.items,
      );
    } catch (e) {
      if (generation != _fetchGeneration) return;
      if (preserveCurrent) return;
      state = HomeError(e.toString());
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
