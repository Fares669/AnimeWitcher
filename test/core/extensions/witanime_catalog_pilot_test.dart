import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/native_provider_resolution.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

void main() {
  test('the build setting controls production Witanime registration', () {
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
      ],
    );
    addTearDown(container.dispose);
    const enabled = bool.fromEnvironment('WITANIME_CATALOG_ENABLED');
    expect(container.read(witanimeCatalogProvider) != null, enabled);
    expect(container.read(activeProviderProvider) is WitanimeProvider, enabled);
  });

  test('the normal build selects the native anime catalog', () {
    final container = ProviderContainer(
      overrides: [
        witanimeCatalogProvider.overrideWithValue(null),
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
      ],
    );
    addTearDown(container.dispose);
    final active = container.read(activeProviderProvider);
    expect(active, isA<AnimeWitcherNativeProvider>());
    expect(container.read(extensionManagerProvider), [active]);
  });

  test(
    'the pilot selects Witanime anime without changing the manga source',
    () async {
      final storage = MemoryStorageService();
      await storage.setActiveProviderId('previous-preference');
      final witanime = WitanimeProvider((uri, {cancelToken}) async {
        expect(uri.path, '/search');
        return '<main><a href="/movie/pilot"><h3>Pilot film</h3></a></main>';
      });
      final nativeCatalog = Provider((ref) => ref.nativeProvider);
      final container = ProviderContainer(
        overrides: [
          witanimeCatalogProvider.overrideWithValue(witanime),
          storageServiceProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);

      final active = container.read(activeProviderProvider);
      expect(active, same(witanime));
      final movie = (await active!.search('Pilot')).single;
      expect(movie.contentType, MultimediaContentType.movie);
      expect(movie.provider, WitanimeProvider.id);
      expect(container.read(nativeCatalog), isA<AnimeWitcherNativeProvider>());
      expect(storage.getActiveProviderId(), 'previous-preference');
    },
  );
}
