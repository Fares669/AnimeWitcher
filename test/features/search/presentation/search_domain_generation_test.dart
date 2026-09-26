import 'dart:async';

import 'package:animewitcher/core/account/animewitcher_character_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
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

final class _DeferredSearchProvider extends AnimeWitcherNativeProvider {
  _DeferredSearchProvider()
    : super(Dio(), SettingsRepository(_TestStorageService()));

  final Completer<ProviderMediaPage> anime = Completer<ProviderMediaPage>();
  final Completer<ProviderMediaPage> manga = Completer<ProviderMediaPage>();
  final Completer<ProviderMediaPage> animation = Completer<ProviderMediaPage>();
  final Completer<AnimeWitcherCharacterPage> characters =
      Completer<AnimeWitcherCharacterPage>();
  int animeCalls = 0;
  int mangaCalls = 0;
  int animationCalls = 0;
  int characterCalls = 0;

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
  Future<AnimeWitcherCharacterPage> searchCharacters(String query) {
    characterCalls++;
    return characters.future;
  }
}

final class _FakeExtensionManager extends ExtensionManager {
  _FakeExtensionManager(this.provider);

  final AnimeWitcherProvider provider;

  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[provider];
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
  test('late anime completion cannot overwrite a newer manga domain', () async {
    final fake = _DeferredSearchProvider();
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _FakeExtensionManager(fake),
        ),
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

  test('characters stay in separate character result state', () async {
    final fake = _DeferredSearchProvider();
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(
          () => _FakeExtensionManager(fake),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(searchDomainProvider.notifier).set(SearchDomain.characters);
    container.read(searchPagedResultsProvider);
    await _flush();

    expect(fake.characterCalls, 1);
    fake.characters.complete(
      const AnimeWitcherCharacterPage(
        items: <AnimeWitcherCharacterHit>[
          AnimeWitcherCharacterHit(
            id: 'c1',
            name: 'Character One',
            imageUrl: 'https://img.example/c1.webp',
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
      const AnimeWitcherCharacterPage(
        items: <AnimeWitcherCharacterHit>[
          AnimeWitcherCharacterHit(id: 'c1', name: 'Character One'),
        ],
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
