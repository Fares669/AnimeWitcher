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
  Completer<MangaLatestChapterPage> manga = Completer<MangaLatestChapterPage>();
  int mangaCalls = 0;

  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) {
    mangaCalls++;
    return manga.future;
  }
}

final class _DeferredHomeProvider extends _SlowMangaProvider {
  final home = Completer<Map<String, List<MultimediaItem>>>();

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() => home.future;
}

final class _AnimeOnlyProvider extends _LatestMangaFailsProvider {
  int mangaCalls = 0;
  @override
  String get packageName => 'alternate.anime';
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};
  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) async {
    mangaCalls++;
    throw StateError('wrong manga provider');
  }
}

final class _AnimeAndMangaProvider extends _AnimeOnlyProvider {
  @override
  Set<ProviderType> get supportedTypes => const {
    ProviderType.anime,
    ProviderType.manga,
  };
}

final class _NativeMangaProvider extends _SlowMangaProvider {
  @override
  String get packageName => 'com.fares669.animewitcher.native';
}

final class _Manager extends ExtensionManager {
  _Manager(this.manga, this.anime);
  final AnimeWitcherProvider manga;
  final AnimeWitcherProvider anime;
  @override
  List<AnimeWitcherProvider> build() => [manga, anime];
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

MangaLatestChapterPage _mangaPage(String title) => MangaLatestChapterPage(
  items: [
    MangaLatestChapter(
      manga: MultimediaItem(title: title, url: '/manga/$title', posterUrl: ''),
      chapter: const MangaChapter(
        id: '1',
        mangaId: 'm1',
        url: '/chapter',
        name: '1',
      ),
    ),
  ],
  nextOffset: 1,
  hasMore: false,
);

void main() {
  test('Rift failure never displays AnimeWitcher manga chapters', () async {
    final manga = _SlowMangaProvider();
    final rift = AnimeRiftProvider();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(rift),
        extensionManagerProvider.overrideWith(() => _Manager(manga, rift)),
      ],
    );
    addTearDown(container.dispose);
    container.listen<HomeState>(homeDataProvider, (_, _) {});
    await _flush();
    await _flush();

    manga.manga = Completer<MangaLatestChapterPage>();
    final refresh = container
        .read(homeDataProvider.notifier)
        .fetch(keepCurrent: true);
    expect(container.read(homeDataProvider), isA<HomeProviderUnavailable>());
    await refresh;
    await _flush();

    final state = container.read(homeDataProvider) as HomeProviderUnavailable;
    expect(state.latestManga, isEmpty);
    expect(manga.mangaCalls, 0);
  });

  test(
    'an empty manga refresh clears old chapters while Rift is unavailable',
    () async {
      final manga = _SlowMangaProvider();
      final rift = AnimeRiftProvider();
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWithValue(rift),
          extensionManagerProvider.overrideWith(() => _Manager(manga, rift)),
        ],
      );
      addTearDown(container.dispose);
      container.listen<HomeState>(homeDataProvider, (_, _) {});
      await _flush();
      await _flush();

      manga.manga = Completer<MangaLatestChapterPage>();
      final refresh = container
          .read(homeDataProvider.notifier)
          .fetch(keepCurrent: true);
      await refresh;
      await _flush();
      expect(
        (container.read(
          homeDataProvider,
        ) as HomeProviderUnavailable).latestManga,
        isEmpty,
      );
      expect(manga.mangaCalls, 0);
    },
  );

  test(
    'manga arriving before anime home is included in its final state',
    () async {
      final provider = _DeferredHomeProvider();
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWithValue(provider),
          extensionManagerProvider.overrideWith(
            () => _Manager(provider, provider),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen<HomeState>(homeDataProvider, (_, _) {});
      await _flush();
      provider.manga.complete(_mangaPage('Early manga'));
      await _flush();
      expect(container.read(homeDataProvider), isA<HomeLoading>());
      provider.home.complete({'anime': []});
      await _flush();
      expect(
        (container.read(
          homeDataProvider,
        ) as HomeSuccess).latestManga.single.manga.title,
        'Early manga',
      );
    },
  );

  test('a manga response after home disposal is ignored', () async {
    final provider = _SlowMangaProvider();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(provider),
        extensionManagerProvider.overrideWith(
          () => _Manager(provider, provider),
        ),
      ],
    );
    container.listen<HomeState>(homeDataProvider, (_, _) {});
    await _flush();
    container.dispose();
    provider.manga.complete(_mangaPage('Late manga'));
    await _flush();
  });

  test('early manga survives a later Rift unavailable response', () async {
    final provider = _DeferredHomeProvider();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(provider),
        extensionManagerProvider.overrideWith(
          () => _Manager(provider, provider),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen<HomeState>(homeDataProvider, (_, _) {});
    await _flush();
    provider.manga.complete(_mangaPage('Early manga'));
    await _flush();
    provider.home.completeError(const AnimeRiftAccessUnavailable());
    await _flush();
    expect(
      (container.read(
        homeDataProvider,
      ) as HomeProviderUnavailable).latestManga.single.manga.title,
      'Early manga',
    );
  });

  test('a late manga response cannot replace a newer fetch', () async {
    final provider = _SlowMangaProvider();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(provider),
        extensionManagerProvider.overrideWith(
          () => _Manager(provider, provider),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen<HomeState>(homeDataProvider, (_, _) {});
    await _flush();
    final oldManga = provider.manga;
    provider.manga = Completer<MangaLatestChapterPage>();
    await container.read(homeDataProvider.notifier).fetch(keepCurrent: true);
    provider.manga.complete(_mangaPage('New manga'));
    await _flush();
    oldManga.complete(_mangaPage('Stale manga'));
    await _flush();
    expect(
      (container.read(
        homeDataProvider,
      ) as HomeSuccess).latestManga.single.manga.title,
      'New manga',
    );
  });

  test(
    'Rift error page does not fetch or render native manga chapters',
    () async {
      final manga = _SlowMangaProvider();
      final rift = AnimeRiftProvider();
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWithValue(rift),
          extensionManagerProvider.overrideWith(() => _Manager(manga, rift)),
        ],
      );
      addTearDown(container.dispose);
      container.listen<HomeState>(homeDataProvider, (_, _) {});
      await _flush();
      expect(container.read(homeDataProvider), isA<HomeProviderUnavailable>());
      await _flush();
      expect(
        (container.read(
          homeDataProvider,
        ) as HomeProviderUnavailable).latestManga,
        isEmpty,
      );
    },
  );

  test(
    'latest manga stays on its own source when anime provider changes',
    () async {
      final manga = _SlowMangaProvider();
      final anime = _AnimeOnlyProvider();
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWithValue(anime),
          extensionManagerProvider.overrideWith(() => _Manager(manga, anime)),
        ],
      );
      addTearDown(container.dispose);
      container.listen<HomeState>(homeDataProvider, (_, _) {});
      await _flush();
      expect(anime.mangaCalls, 0);
      manga.manga.complete(
        MangaLatestChapterPage(
          items: [
            MangaLatestChapter(
              manga: MultimediaItem(
                title: 'Manga',
                url: '/manga',
                posterUrl: '',
              ),
              chapter: const MangaChapter(
                id: '1',
                mangaId: 'm1',
                url: '/chapter',
                name: '1',
              ),
            ),
          ],
          nextOffset: 1,
          hasMore: false,
        ),
      );
      await _flush();
      expect(
        (container.read(homeDataProvider) as HomeSuccess).latestManga,
        hasLength(1),
      );
    },
  );

  test(
    'active anime provider cannot replace the independent native manga source',
    () async {
      final manga = _NativeMangaProvider();
      final anime = _AnimeAndMangaProvider();
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWithValue(anime),
          extensionManagerProvider.overrideWith(() => _Manager(manga, anime)),
        ],
      );
      addTearDown(container.dispose);
      container.listen<HomeState>(homeDataProvider, (_, _) {});
      await _flush();
      expect(anime.mangaCalls, 0);
      manga.manga.complete(_mangaPage('Native manga'));
      await _flush();
      expect(
        (container.read(
          homeDataProvider,
        ) as HomeSuccess).latestManga.single.manga.title,
        'Native manga',
      );
    },
  );

  test('latest manga failure does not fail anime home', () async {
    final provider = _LatestMangaFailsProvider();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(provider),
        extensionManagerProvider.overrideWith(
          () => _Manager(provider, provider),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.listen<HomeState>(homeDataProvider, (_, _) {});
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
      overrides: [
        activeProviderProvider.overrideWithValue(provider),
        extensionManagerProvider.overrideWith(
          () => _Manager(provider, provider),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.listen<HomeState>(homeDataProvider, (_, _) {});
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
