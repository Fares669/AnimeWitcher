import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:animewitcher/features/search/presentation/search_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _TestStorageService extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => true;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

class _DeferredSearchProvider extends AnimeWitcherNativeProvider {
  _DeferredSearchProvider()
    : super(Dio(), SettingsRepository(_TestStorageService()));

  final Completer<ProviderMediaPage> anime = Completer<ProviderMediaPage>();
  final Completer<ProviderMediaPage> manga = Completer<ProviderMediaPage>();
  final Completer<ProviderMediaPage> animation = Completer<ProviderMediaPage>();
  final Completer<ProviderCharacterPage> characters =
      Completer<ProviderCharacterPage>();
  int animeCalls = 0;
  int mangaCalls = 0;
  int animationCalls = 0;
  int characterCalls = 0;

  @override
  Future<ProviderSearchFilterOptions> getSearchFilterOptions() async =>
      ProviderSearchFilterOptions(genres: [packageName]);

  @override
  Future<ProviderSearchFilterOptions> getMangaSearchFilterOptions() async =>
      ProviderSearchFilterOptions(genres: ['manga-$packageName']);

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    animeCalls++;
    return (await anime.future).items;
  }

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) {
    animeCalls++;
    return anime.future;
  }

  @override
  Future<ProviderMediaPage> searchMangaPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) {
    mangaCalls++;
    return manga.future;
  }

  @override
  Future<ProviderMediaPage> searchAnimationPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) {
    animationCalls++;
    return animation.future;
  }

  @override
  Future<ProviderCharacterPage> searchCharacterPage(
    String query, {
    int page = 0,
  }) {
    characterCalls++;
    return characters.future;
  }
}

final class _RiftCharacterProvider extends AnimeRiftProvider {
  int characterCalls = 0;

  @override
  Future<ProviderCharacterPage> searchCharacterPage(
    String query, {
    int page = 0,
  }) async {
    characterCalls++;
    return ProviderCharacterPage(
      items: <Actor>[
        Actor(
          id: 'rift-c1',
          name: 'Rift Character',
          image: 'https://images.example/rift-c1.jpg',
        ),
      ],
      page: page,
      hasMore: false,
    );
  }
}

final class _DeferredRiftCharacterProvider extends AnimeRiftProvider {
  final Completer<ProviderCharacterPage> characters =
      Completer<ProviderCharacterPage>();
  int characterCalls = 0;

  @override
  Future<ProviderCharacterPage> searchCharacterPage(
    String query, {
    int page = 0,
  }) {
    characterCalls++;
    return characters.future;
  }
}

final class _AccountSwitchSearchProvider extends AnimeWitcherNativeProvider {
  _AccountSwitchSearchProvider()
    : super(Dio(), SettingsRepository(_TestStorageService()));

  int pageCalls = 0;
  final refreshedPage = Completer<ProviderMediaPage>();
  final refreshedSuggestions = Completer<List<MultimediaItem>>();
  int suggestionCalls = 0;

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) {
    if (++pageCalls == 1) {
      return Future.value(
        ProviderMediaPage(
          items: [_item('previous-account', MultimediaContentType.anime)],
          nextOffset: 0,
          hasMore: false,
        ),
      );
    }
    return refreshedPage.future;
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) {
    if (++suggestionCalls == 1) {
      return Future.value([
        _item('previous-account', MultimediaContentType.anime),
      ]);
    }
    return refreshedSuggestions.future;
  }
}

final class _FakeExtensionManager extends ExtensionManager {
  _FakeExtensionManager(this.provider);

  final AnimeWitcherProvider provider;

  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[provider];
}

final class _NamedDeferredProvider extends _DeferredSearchProvider {
  _NamedDeferredProvider(this.id);

  final String id;
  @override
  String get packageName => id;
}

final class _TwoProviderManager extends ExtensionManager {
  _TwoProviderManager(this.first, this.second);
  final AnimeWitcherProvider first;
  final AnimeWitcherProvider second;
  @override
  List<AnimeWitcherProvider> build() => [first, second];
}

final class _TestActiveProvider extends ActiveProvider {
  _TestActiveProvider(this.initial);
  final AnimeWitcherProvider initial;
  @override
  AnimeWitcherProvider? build() => initial;
  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

MultimediaItem _item(String title, MultimediaContentType type) =>
    MultimediaItem(
      title: title,
      url: 'test://${Uri.encodeComponent(title)}',
      posterUrl: '',
      contentType: type,
    );

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test(
    'account revision removes old paged results even when refresh fails',
    () async {
      final provider = _AccountSwitchSearchProvider();
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _FakeExtensionManager(provider),
          ),
          activeProviderProvider.overrideWith(
            () => _TestActiveProvider(provider),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(searchPagedResultsProvider);
      await _flush();
      expect(container.read(searchPagedResultsProvider).results, isNotEmpty);

      container.read(accountDataRevisionProvider.notifier).bump();
      expect(container.read(searchPagedResultsProvider).results, isEmpty);
      await _flush();
      expect(provider.pageCalls, 2);
      provider.refreshedPage.completeError(
        StateError('new account unavailable'),
      );
      await _flush();
      expect(container.read(searchPagedResultsProvider).results, isEmpty);
    },
  );

  test('account revision purges instant results and refetches query', () async {
    final provider = _AccountSwitchSearchProvider();
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _FakeExtensionManager(provider),
        ),
        activeProviderProvider.overrideWith(
          () => _TestActiveProvider(provider),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      searchSuggestionControllerProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    container
        .read(searchSuggestionControllerProvider.notifier)
        .onQueryChanged('hero');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _flush();
    expect(
      container.read(searchSuggestionControllerProvider).items,
      isNotEmpty,
    );

    container.read(accountDataRevisionProvider.notifier).bump();
    expect(container.read(searchSuggestionControllerProvider).items, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(provider.suggestionCalls, 2);
    provider.refreshedSuggestions.completeError(StateError('account changed'));
    await _flush();
    expect(container.read(searchSuggestionControllerProvider).items, isEmpty);
  });

  test('characters catalog follows the active capable anime provider', () {
    final rift = AnimeRiftProvider();

    expect(
      searchCatalogProvider(SearchDomain.characters, <AnimeWitcherProvider>[
        rift,
      ], activeAnimeProvider: rift),
      same(rift),
    );
  });

  test(
    'Rift tags do not survive an anime provider or manga domain switch',
    () async {
      final rift = AnimeRiftProvider();
      final catalog = _DeferredSearchProvider();
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _TwoProviderManager(rift, catalog),
          ),
          activeProviderProvider.overrideWith(() => _TestActiveProvider(rift)),
        ],
      );
      addTearDown(container.dispose);
      container.read(searchDomainProvider.notifier).set(SearchDomain.anime);
      container
          .read(searchProviderFiltersProvider.notifier)
          .set(
            const ProviderSearchFilters(tags: {'بطل مضاد'}, sort: 'year_desc'),
          );
      expect(container.read(searchProviderFiltersProvider).tags, isNotEmpty);
      await container.read(activeProviderProvider.notifier).set(catalog);
      expect(container.read(searchProviderFiltersProvider).tags, isEmpty);
      await container.read(activeProviderProvider.notifier).set(rift);
      container
          .read(searchProviderFiltersProvider.notifier)
          .set(const ProviderSearchFilters(tags: {'بطل مضاد'}));
      container.read(searchDomainProvider.notifier).set(SearchDomain.manga);
      expect(container.read(searchProviderFiltersProvider).tags, isEmpty);
      final options = await searchFilterOptionsFor(
        SearchDomain.manga,
        rift,
        catalog,
      );
      expect(options.tags, isEmpty);
      expect(options.genres, ['manga-${catalog.packageName}']);
    },
  );

  test(
    'Rift without build configuration reports a recoverable connection error',
    () async {
      final provider = AnimeRiftProvider();
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _FakeExtensionManager(provider),
          ),
          activeProviderProvider.overrideWith(
            () => _TestActiveProvider(provider),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(searchPagedResultsProvider);
      await _flush();
      expect(
        container.read(searchPagedResultsProvider).errorMessage,
        contains('إعدادات المزوّد'),
      );
    },
  );

  test(
    'filter options follow anime selection without changing manga or animation',
    () async {
      final original = _NamedDeferredProvider('original');
      final selected = _NamedDeferredProvider('selected');
      expect(
        (await searchFilterOptionsFor(
          SearchDomain.anime,
          selected,
          original,
        )).genres,
        ['selected'],
      );
      expect(
        (await searchFilterOptionsFor(
          SearchDomain.animation,
          selected,
          original,
        )).genres,
        ['original'],
      );
      expect(
        (await searchFilterOptionsFor(
          SearchDomain.manga,
          selected,
          original,
        )).genres,
        ['manga-original'],
      );
    },
  );

  test('filter staleness follows only the anime catalog', () {
    expect(
      searchFilterRequestIsStale(SearchDomain.anime, 'old', 'new'),
      isTrue,
    );
    for (final domain in <SearchDomain>[
      SearchDomain.all,
      SearchDomain.animation,
      SearchDomain.manga,
      SearchDomain.characters,
    ]) {
      expect(
        searchFilterRequestIsStale(domain, 'old', 'new'),
        isFalse,
        reason: domain.name,
      );
    }
  });

  test(
    'suggestions follow provider switches and discard older responses',
    () async {
      final original = _NamedDeferredProvider('original');
      final alternate = _NamedDeferredProvider('alternate');
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _TwoProviderManager(original, alternate),
          ),
          activeProviderProvider.overrideWith(
            () => _TestActiveProvider(original),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        searchSuggestionControllerProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      container
          .read(searchSuggestionControllerProvider.notifier)
          .onQueryChanged('anime');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(original.animeCalls, 1);
      await container.read(activeProviderProvider.notifier).set(alternate);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(alternate.animeCalls, 1);
      alternate.anime.complete(
        ProviderMediaPage(
          items: [_item('new', MultimediaContentType.anime)],
          nextOffset: 0,
          hasMore: false,
        ),
      );
      await _flush();
      original.anime.complete(
        ProviderMediaPage(
          items: [_item('old', MultimediaContentType.anime)],
          nextOffset: 0,
          hasMore: false,
        ),
      );
      await _flush();
      expect(
        container.read(searchSuggestionControllerProvider).items.single.title,
        'new',
      );
    },
  );

  test(
    'changing the search tab clears suggestions and loads that catalog',
    () async {
      final catalog = _DeferredSearchProvider();
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _FakeExtensionManager(catalog),
          ),
          activeProviderProvider.overrideWith(
            () => _TestActiveProvider(catalog),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        searchSuggestionControllerProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      container
          .read(searchSuggestionControllerProvider.notifier)
          .onQueryChanged('hero');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      catalog.anime.complete(
        ProviderMediaPage(
          items: [_item('Anime suggestion', MultimediaContentType.anime)],
          nextOffset: 0,
          hasMore: false,
        ),
      );
      await _flush();
      expect(
        container.read(searchSuggestionControllerProvider).items.single.title,
        'Anime suggestion',
      );

      container.read(searchDomainProvider.notifier).set(SearchDomain.manga);
      final pending = container.read(searchSuggestionControllerProvider);
      expect(pending.items, isEmpty);
      expect(pending.suggestions, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(catalog.mangaCalls, 1);
      catalog.manga.complete(
        ProviderMediaPage(
          items: [_item('Manga suggestion', MultimediaContentType.manga)],
          nextOffset: 0,
          hasMore: false,
        ),
      );
      await _flush();
      expect(
        container.read(searchSuggestionControllerProvider).items.single.title,
        'Manga suggestion',
      );
    },
  );

  test('a late anime suggestion cannot replace the manga tab', () async {
    final catalog = _DeferredSearchProvider();
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _FakeExtensionManager(catalog),
        ),
        activeProviderProvider.overrideWith(() => _TestActiveProvider(catalog)),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      searchSuggestionControllerProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    container
        .read(searchSuggestionControllerProvider.notifier)
        .onQueryChanged('hero');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(catalog.animeCalls, 1);

    container.read(searchDomainProvider.notifier).set(SearchDomain.manga);
    expect(container.read(searchSuggestionControllerProvider).items, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    catalog.manga.complete(
      ProviderMediaPage(
        items: [_item('new manga', MultimediaContentType.manga)],
        nextOffset: 0,
        hasMore: false,
      ),
    );
    await _flush();
    catalog.anime.complete(
      ProviderMediaPage(
        items: [_item('old anime', MultimediaContentType.anime)],
        nextOffset: 0,
        hasMore: false,
      ),
    );
    await _flush();
    expect(
      container.read(searchSuggestionControllerProvider).items.single.title,
      'new manga',
    );
  });

  test('Rift failure leaves independent all-tab suggestions visible', () async {
    final catalog = _DeferredSearchProvider();
    final rift = AnimeRiftProvider();
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _TwoProviderManager(rift, catalog),
        ),
        activeProviderProvider.overrideWith(() => _TestActiveProvider(rift)),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      searchSuggestionControllerProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    container.read(searchDomainProvider.notifier).set(SearchDomain.all);
    container
        .read(searchSuggestionControllerProvider.notifier)
        .onQueryChanged('hero');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    catalog.manga.complete(
      ProviderMediaPage(
        items: [_item('manga', MultimediaContentType.manga)],
        nextOffset: 0,
        hasMore: false,
      ),
    );
    catalog.animation.complete(
      ProviderMediaPage(
        items: [_item('animation', MultimediaContentType.other)],
        nextOffset: 0,
        hasMore: false,
      ),
    );
    catalog.characters.complete(
      const ProviderCharacterPage(items: <Actor>[], page: 0, hasMore: false),
    );
    await _flush();
    final result = container.read(searchSuggestionControllerProvider);
    expect(result.isLoading, isFalse);
    expect(result.manga.single.title, 'manga');
    expect(result.animation.single.title, 'animation');
    expect(result.items, isEmpty);
  });

  test(
    'a Rift-first provider list still selects the native manga catalog',
    () async {
      final catalog = _DeferredSearchProvider();
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _TwoProviderManager(AnimeRiftProvider(), catalog),
          ),
          activeProviderProvider.overrideWith(
            () => _TestActiveProvider(AnimeRiftProvider()),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(searchDomainProvider.notifier).set(SearchDomain.manga);
      container.read(searchPagedResultsProvider);
      await _flush();
      expect(catalog.mangaCalls, 1);
      catalog.manga.complete(
        ProviderMediaPage(
          items: [_item('Manga hit', MultimediaContentType.manga)],
          nextOffset: 0,
          hasMore: false,
        ),
      );
      await _flush();
      expect(
        container
            .read(searchPagedResultsProvider)
            .results
            .single
            .results
            .single
            .title,
        'Manga hit',
      );
    },
  );

  test(
    'Rift failure leaves independent all-tab search results visible',
    () async {
      final catalog = _DeferredSearchProvider();
      final rift = AnimeRiftProvider();
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _TwoProviderManager(rift, catalog),
          ),
          activeProviderProvider.overrideWith(() => _TestActiveProvider(rift)),
        ],
      );
      addTearDown(container.dispose);
      container.read(searchDomainProvider.notifier).set(SearchDomain.all);
      container.read(searchPagedResultsProvider);
      await _flush();
      catalog.manga.complete(
        ProviderMediaPage(
          items: [_item('Manga hit', MultimediaContentType.manga)],
          nextOffset: 1,
          hasMore: false,
        ),
      );
      catalog.animation.complete(
        ProviderMediaPage(
          items: [_item('Animation hit', MultimediaContentType.other)],
          nextOffset: 1,
          hasMore: false,
        ),
      );
      await _flush();
      final state = container.read(searchPagedResultsProvider);
      expect(state.isLoading, isFalse);
      expect(state.errorMessage, isNull);
      expect(state.results.map((group) => group.providerId), [
        'animation',
        'manga',
      ]);
      expect(
        state.results
            .expand((group) => group.results)
            .map((item) => item.title),
        ['Animation hit', 'Manga hit'],
      );
      expect(state.characters, isEmpty);
      expect(catalog.characterCalls, 0);
    },
  );

  test(
    'switching anime provider drops stale results and keeps manga independent',
    () async {
      final original = _NamedDeferredProvider('original');
      final alternate = _NamedDeferredProvider('alternate');
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _TwoProviderManager(original, alternate),
          ),
          activeProviderProvider.overrideWith(
            () => _TestActiveProvider(original),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(searchPagedResultsProvider);
      await _flush();
      expect(original.animeCalls, 1);
      await container.read(activeProviderProvider.notifier).set(alternate);
      await _flush();
      expect(alternate.animeCalls, 1);
      alternate.anime.complete(
        ProviderMediaPage(
          items: [_item('alternate', MultimediaContentType.anime)],
          nextOffset: 0,
          hasMore: false,
        ),
      );
      await _flush();
      original.anime.complete(
        ProviderMediaPage(
          items: [_item('stale', MultimediaContentType.anime)],
          nextOffset: 0,
          hasMore: false,
        ),
      );
      await _flush();
      expect(
        container
            .read(searchPagedResultsProvider)
            .results
            .single
            .results
            .single
            .title,
        'alternate',
      );
      container.read(searchDomainProvider.notifier).set(SearchDomain.manga);
      await _flush();
      expect(original.mangaCalls, 1);
      expect(alternate.mangaCalls, 0);
    },
  );

  test('late anime completion cannot overwrite a newer manga domain', () async {
    final fake = _DeferredSearchProvider();
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _FakeExtensionManager(fake),
        ),
        activeProviderProvider.overrideWith(() => _TestActiveProvider(fake)),
      ],
    );
    addTearDown(container.dispose);

    container.read(searchPagedResultsProvider);
    await _flush();
    expect(fake.animeCalls, 1);

    container.read(searchDomainProvider.notifier).set(SearchDomain.manga);
    await _flush();
    expect(fake.mangaCalls, 1);

    fake.manga.complete(
      ProviderMediaPage(
        items: <MultimediaItem>[
          _item('Manga result', MultimediaContentType.manga),
        ],
        nextOffset: 30,
        hasMore: false,
      ),
    );
    await _flush();

    expect(
      container
          .read(searchPagedResultsProvider)
          .results
          .expand((entry) => entry.results)
          .map((item) => item.title),
      contains('Manga result'),
    );

    fake.anime.complete(
      ProviderMediaPage(
        items: <MultimediaItem>[
          _item('Late anime result', MultimediaContentType.anime),
        ],
        nextOffset: 30,
        hasMore: false,
      ),
    );
    await _flush();

    final renderedTitles = container
        .read(searchPagedResultsProvider)
        .results
        .expand((entry) => entry.results)
        .map((item) => item.title)
        .toList(growable: false);
    expect(renderedTitles, contains('Manga result'));
    expect(renderedTitles, isNot(contains('Late anime result')));
  });

  test(
    'animation domain uses the animation catalog instead of anime',
    () async {
      final fake = _DeferredSearchProvider();
      final container = ProviderContainer(
        overrides: [
          extensionManagerProvider.overrideWith(
            () => _FakeExtensionManager(fake),
          ),
          activeProviderProvider.overrideWith(() => _TestActiveProvider(fake)),
        ],
      );
      addTearDown(container.dispose);

      container.read(searchDomainProvider.notifier).set(SearchDomain.animation);
      container.read(searchPagedResultsProvider);
      await _flush();

      expect(fake.animationCalls, 1);
      expect(fake.animeCalls, 0);

      fake.animation.complete(
        ProviderMediaPage(
          items: <MultimediaItem>[
            _item('Animation result', MultimediaContentType.movie),
          ],
          nextOffset: 30,
          hasMore: false,
        ),
      );
      await _flush();

      final titles = container
          .read(searchPagedResultsProvider)
          .results
          .expand((entry) => entry.results)
          .map((item) => item.title);
      expect(titles, contains('Animation result'));
    },
  );

  test('characters domain queries the active Rift provider', () async {
    final rift = _RiftCharacterProvider();
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _FakeExtensionManager(rift),
        ),
        activeProviderProvider.overrideWith(() => _TestActiveProvider(rift)),
      ],
    );
    addTearDown(container.dispose);

    container.read(searchDomainProvider.notifier).set(SearchDomain.characters);
    container.read(searchPagedResultsProvider);
    await _flush();

    expect(rift.characterCalls, 1);
  });

  test('late Rift characters cannot leak after switching providers', () async {
    final rift = _DeferredRiftCharacterProvider();
    final native = _NamedDeferredProvider('native-after-rift');
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _TwoProviderManager(rift, native),
        ),
        activeProviderProvider.overrideWith(() => _TestActiveProvider(rift)),
      ],
    );
    addTearDown(container.dispose);

    container.read(searchDomainProvider.notifier).set(SearchDomain.characters);
    container.read(searchPagedResultsProvider);
    await _flush();
    expect(rift.characterCalls, 1);

    await container.read(activeProviderProvider.notifier).set(native);
    await _flush();
    expect(native.characterCalls, 1);

    native.characters.complete(
      ProviderCharacterPage(
        items: <Actor>[Actor(id: 'native-c1', name: 'Native Character')],
        page: 0,
        hasMore: false,
      ),
    );
    await _flush();
    expect(
      container.read(searchPagedResultsProvider).characters.single.name,
      'Native Character',
    );

    rift.characters.complete(
      ProviderCharacterPage(
        items: <Actor>[Actor(id: 'rift-c1', name: 'Late Rift Character')],
        page: 0,
        hasMore: false,
      ),
    );
    await _flush();
    expect(
      container.read(searchPagedResultsProvider).characters.single.name,
      'Native Character',
    );
  });

  test('characters stay in separate character result state', () async {
    final fake = _DeferredSearchProvider();
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _FakeExtensionManager(fake),
        ),
        activeProviderProvider.overrideWith(() => _TestActiveProvider(fake)),
      ],
    );
    addTearDown(container.dispose);

    container.read(searchDomainProvider.notifier).set(SearchDomain.characters);
    container.read(searchPagedResultsProvider);
    await _flush();

    expect(fake.characterCalls, 1);
    fake.characters.complete(
      ProviderCharacterPage(
        items: <Actor>[
          Actor(
            id: 'c1',
            name: 'Character One',
            image: 'https://img.example/c1.webp',
          ),
        ],
        page: 0,
        hasMore: false,
      ),
    );
    await _flush();

    final state = container.read(searchPagedResultsProvider);
    expect(state.results, isEmpty);
    expect(state.characters.map((item) => item.name), <String>[
      'Character One',
    ]);
  });

  test('all searches every category at once and names each group', () async {
    final fake = _DeferredSearchProvider();
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _FakeExtensionManager(fake),
        ),
        activeProviderProvider.overrideWith(() => _TestActiveProvider(fake)),
      ],
    );
    addTearDown(container.dispose);

    container.read(searchDomainProvider.notifier).set(SearchDomain.all);
    container.read(searchPagedResultsProvider);
    await _flush();

    // All four asked at once, not one after another.
    expect(fake.animeCalls, 1);
    expect(fake.animationCalls, 1);
    expect(fake.mangaCalls, 1);
    expect(fake.characterCalls, 1);

    fake.anime.complete(
      ProviderMediaPage(
        items: <MultimediaItem>[
          _item('Anime hit', MultimediaContentType.anime),
        ],
        nextOffset: 30,
        hasMore: true,
      ),
    );
    fake.animation.complete(
      const ProviderMediaPage(
        items: <MultimediaItem>[],
        nextOffset: 0,
        hasMore: false,
      ),
    );
    fake.manga.complete(
      ProviderMediaPage(
        items: <MultimediaItem>[
          _item('Manga hit', MultimediaContentType.manga),
        ],
        nextOffset: 30,
        hasMore: true,
      ),
    );
    fake.characters.complete(
      ProviderCharacterPage(
        items: <Actor>[Actor(id: 'c1', name: 'Character One')],
        page: 0,
        hasMore: false,
      ),
    );
    await _flush();

    final state = container.read(searchPagedResultsProvider);
    // One group per category that found something, named after it; the
    // empty animation list is left out.
    expect(state.results.map((group) => group.providerId), <String>[
      'anime',
      'manga',
    ]);
    expect(state.results.first.results.single.title, 'Anime hit');
    expect(state.characters.single.name, 'Character One');
    // No paging here: each group leads into its own category for more.
    expect(state.hasMore, isFalse);
    expect(state.isLoading, isFalse);
  });

  test('one failing category does not sink the others in all', () async {
    final fake = _DeferredSearchProvider();
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _FakeExtensionManager(fake),
        ),
        activeProviderProvider.overrideWith(() => _TestActiveProvider(fake)),
      ],
    );
    addTearDown(container.dispose);

    container.read(searchDomainProvider.notifier).set(SearchDomain.all);
    container.read(searchPagedResultsProvider);
    await _flush();

    fake.anime.completeError(StateError('anime is down'));
    fake.animation.completeError(StateError('animation is down'));
    fake.manga.complete(
      ProviderMediaPage(
        items: <MultimediaItem>[
          _item('Manga hit', MultimediaContentType.manga),
        ],
        nextOffset: 30,
        hasMore: false,
      ),
    );
    fake.characters.completeError(StateError('characters are down'));
    await _flush();

    final state = container.read(searchPagedResultsProvider);
    expect(state.errorMessage, isNull);
    expect(state.results.single.providerId, 'manga');
  });
}
