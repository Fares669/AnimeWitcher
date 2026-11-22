import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/native_provider_resolution.dart';
import 'package:animewitcher/core/extensions/providers/anime3rb_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

void main() {
  test('the build setting controls Witanime registration with default enabled', () {
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
      ],
    );
    addTearDown(container.dispose);
    const enabled = bool.fromEnvironment(
      'WITANIME_CATALOG_ENABLED',
      defaultValue: true,
    );
    expect(container.read(witanimeCatalogProvider) != null, enabled);
    expect(
      container.read(extensionManagerProvider).any((p) => p is WitanimeProvider),
      enabled,
    );
  });

  test('the native-only override selects the native anime catalog', () {
    final container = ProviderContainer(
      overrides: [
        witanimeCatalogProvider.overrideWithValue(null),
        anime3rbCatalogProvider.overrideWithValue(null),
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
      ],
    );
    addTearDown(container.dispose);
    final active = container.read(activeProviderProvider);
    expect(active, isA<AnimeWitcherNativeProvider>());
    expect(container.read(extensionManagerProvider), [active]);
  });

  test(
    'users can switch freely between AnimeWitcher and Witanime without changing manga',
    () async {
      final storage = MemoryStorageService();
      final witanime = WitanimeProvider((uri, {cancelToken}) async {
        expect(uri.path, '/search');
        return '<main><a href="/movie/pilot"><h3>Pilot film</h3></a></main>';
      });
      final nativeCatalog = Provider((ref) => ref.nativeProvider);
      final container = ProviderContainer(
        overrides: [
          witanimeCatalogProvider.overrideWithValue(witanime),
          anime3rbCatalogProvider.overrideWithValue(null),
          storageServiceProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(extensionManagerProvider).length,
        2,
      );
      expect(
        container.read(activeProviderProvider),
        isA<AnimeWitcherNativeProvider>(),
      );

      await container.read(activeProviderProvider.notifier).set(witanime);
      final active = container.read(activeProviderProvider);
      expect(active, same(witanime));
      expect(storage.getActiveProviderId(), WitanimeProvider.id);

      final movie = (await active!.search('Pilot')).single;
      expect(movie.contentType, MultimediaContentType.movie);
      expect(movie.provider, WitanimeProvider.id);
      expect(container.read(nativeCatalog), isA<AnimeWitcherNativeProvider>());

      final nativeProvider = container
          .read(extensionManagerProvider)
          .whereType<AnimeWitcherNativeProvider>()
          .single;
      await container.read(activeProviderProvider.notifier).set(nativeProvider);
      expect(container.read(activeProviderProvider), same(nativeProvider));
      expect(storage.getActiveProviderId(), nativeProvider.packageName);
    },
  );

  test(
    'users can switch across AnimeWitcher, Witanime, and Anime3rb without changing manga',
    () async {
      final storage = MemoryStorageService();
      final container = ProviderContainer(
        overrides: [storageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      final providers = container.read(extensionManagerProvider);
      expect(providers.whereType<AnimeWitcherNativeProvider>(), hasLength(1));
      expect(providers.whereType<WitanimeProvider>(), hasLength(1));
      expect(providers.whereType<Anime3rbProvider>(), hasLength(1));

      final anime3rb = providers.whereType<Anime3rbProvider>().single;
      await container.read(activeProviderProvider.notifier).set(anime3rb);
      expect(container.read(activeProviderProvider), same(anime3rb));
      expect(storage.getActiveProviderId(), Anime3rbProvider.id);
    },
  );
}
