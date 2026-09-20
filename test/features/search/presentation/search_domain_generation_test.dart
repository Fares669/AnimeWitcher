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
  final Completer<AnimeWitcherCharacterPage> characters =
      Completer<AnimeWitcherCharacterPage>();
  int animeCalls = 0;
  int mangaCalls = 0;
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

MultimediaItem _item(String title, MultimediaContentType type) => MultimediaItem(
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

    container
        .read(searchDomainProvider.notifier)
        .set(SearchDomain.manga);
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

    container
        .read(searchDomainProvider.notifier)
        .set(SearchDomain.characters);
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

}