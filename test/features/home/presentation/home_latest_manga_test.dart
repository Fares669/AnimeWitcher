import 'dart:async';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _LatestMangaFailsProvider extends AnimeWitcherProvider {
  @override
  String get packageName => 'home.latest.manga.fail';

  @override
  String get name => 'Fake';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const <ProviderType>{
    ProviderType.anime,
    ProviderType.manga,
  };

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async =>
      <String, List<MultimediaItem>>{
        'الحلقات الجديدة': <MultimediaItem>[
          MultimediaItem(
            title: 'Anime survives',
            url: 'https://example.test/anime',
            posterUrl: '',
          ),
        ],
      };

  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) async {
    throw StateError('latest manga unavailable');
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const <MultimediaItem>[];

  @override
  Future<MultimediaItem> getDetails(String url) async =>
      MultimediaItem(title: 'Details', url: url, posterUrl: '');

  @override
  Future<List<StreamResult>> loadStreams(String url) async =>
      const <StreamResult>[];
}

/// Answers the new manga chapters only when the test says so.
final class _SlowMangaProvider extends _LatestMangaFailsProvider {
  final Completer<MangaLatestChapterPage> manga =
      Completer<MangaLatestChapterPage>();

  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) => manga.future;
}

final class _AnimeOnlyProvider extends _LatestMangaFailsProvider {
  int mangaCalls = 0;
  @override String get packageName => 'alternate.anime';
  @override Set<ProviderType> get supportedTypes => const {ProviderType.anime};
  @override Future<MangaLatestChapterPage> getLatestMangaPage({int offset = 0, int limit = 30}) async {
    mangaCalls++;
    throw StateError('wrong manga provider');
  }
}

final class _Manager extends ExtensionManager {
  _Manager(this.manga, this.anime);
  final AnimeWitcherProvider manga;
  final AnimeWitcherProvider anime;
  @override List<AnimeWitcherProvider> build() => [manga, anime];
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('manga chapters remain available while Rift connection is unavailable', () async {
    final manga = _SlowMangaProvider();
    final rift = AnimeRiftProvider();
    final container = ProviderContainer(overrides: [
      activeProviderProvider.overrideWithValue(rift),
      extensionManagerProvider.overrideWith(() => _Manager(manga, rift)),
    ]);
    addTearDown(container.dispose);
    container.listen<HomeState>(homeDataProvider, (_, __) {});
    await _flush();
    expect(container.read(homeDataProvider), isA<HomeProviderUnavailable>());
    manga.manga.complete(MangaLatestChapterPage(items: [
      MangaLatestChapter(manga: MultimediaItem(title: 'Manga', url: '/manga', posterUrl: ''),
        chapter: const MangaChapter(id: '1', mangaId: 'm1', url: '/chapter', name: '1')),
    ], nextOffset: 1, hasMore: false));
    await _flush();
    expect((container.read(homeDataProvider) as HomeProviderUnavailable).latestManga, hasLength(1));
  });

  test('latest manga stays on its own source when anime provider changes', () async {
    final manga = _SlowMangaProvider();
    final anime = _AnimeOnlyProvider();
    final container = ProviderContainer(overrides: [
      activeProviderProvider.overrideWithValue(anime),
      extensionManagerProvider.overrideWith(() => _Manager(manga, anime)),
    ]);
    addTearDown(container.dispose);
    container.listen<HomeState>(homeDataProvider, (_, __) {});
    await _flush();
    expect(anime.mangaCalls, 0);
    manga.manga.complete(MangaLatestChapterPage(items: [
      MangaLatestChapter(manga: MultimediaItem(title: 'Manga', url: '/manga', posterUrl: ''),
        chapter: const MangaChapter(id: '1', mangaId: 'm1', url: '/chapter', name: '1')),
    ], nextOffset: 1, hasMore: false));
    await _flush();
    expect((container.read(homeDataProvider) as HomeSuccess).latestManga, hasLength(1));
  });

  test('latest manga failure does not fail anime home', () async {
    final provider = _LatestMangaFailsProvider();
    final container = ProviderContainer(
      overrides: [activeProviderProvider.overrideWithValue(provider)],
    );
    addTearDown(container.dispose);

    container.listen<HomeState>(homeDataProvider, (_, __) {});
    await _flush();

    final state = container.read(homeDataProvider);
    expect(state, isA<HomeSuccess>());
    final success = state as HomeSuccess;
    expect(
      success.data.values.expand((items) => items).single.title,
      'Anime survives',
    );
    expect(success.latestManga, isEmpty);
  });

  test('home shows before a slow manga answer, which joins it later', () async {
    final provider = _SlowMangaProvider();
    final container = ProviderContainer(
      overrides: [activeProviderProvider.overrideWithValue(provider)],
    );
    addTearDown(container.dispose);

    container.listen<HomeState>(homeDataProvider, (_, __) {});
    await _flush();

    // The anime rows are on screen while the manga is still coming.
    final early = container.read(homeDataProvider);
    expect(early, isA<HomeSuccess>());
    expect((early as HomeSuccess).latestManga, isEmpty);

    provider.manga.complete(
      MangaLatestChapterPage(
        items: <MangaLatestChapter>[
          MangaLatestChapter(
            manga: MultimediaItem(
              title: 'Manga',
              url: 'https://example.test/manga',
              posterUrl: '',
            ),
            chapter: const MangaChapter(
              id: '1',
              mangaId: 'm1',
              url: 'chapter://1',
              name: '1',
              number: 1,
            ),
          ),
        ],
        nextOffset: 1,
        hasMore: false,
      ),
    );
    await _flush();

    final late = container.read(homeDataProvider) as HomeSuccess;
    expect(late.latestManga, hasLength(1));
    expect(
      late.data.values.expand((items) => items).single.title,
      'Anime survives',
    );
  });
}
