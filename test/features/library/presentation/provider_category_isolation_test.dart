import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Storage extends StorageService {
  final values = <String, String>{};
  String nativeSelectedCategory = 'completed';

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  String getSelectedLibraryCategory() => nativeSelectedCategory;

  @override
  Future<void> setSelectedLibraryCategory(String category) async {
    nativeSelectedCategory = category;
  }

  @override
  List<MultimediaItem> getLibraryItems({String? category}) =>
      category == 'completed'
      ? [MultimediaItem(title: 'Native Completed', url: 'same', posterUrl: '')]
      : [];
}

class _Source extends AnimeWitcherProvider {
  _Source(this.id);

  final String id;

  @override
  String get packageName => id;
  @override
  String get name => id;
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => ['ar'];
  @override
  Set<ProviderType> get supportedTypes => {ProviderType.anime};
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => [];
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => {};
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) async => [];
}

class _Active extends ActiveProvider {
  _Active(this.initial);
  final AnimeWitcherProvider initial;

  @override
  AnimeWitcherProvider? build() => initial;

  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

void main() {
  test(
    'first Rift visit ignores category previously selected in Native',
    () async {
      final storage = _Storage();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      final native = _Source('com.fares669.animewitcher.native');
      final rift = _Source(animeRiftProviderId);
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          activeProviderProvider.overrideWith(() => _Active(native)),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(libraryProvider.notifier)
          .selectCategory(LibraryCategory.planToWatch);
      expect(storage.nativeSelectedCategory, 'pinned');
      expect(storage.getString('animerift_library_anime_category'), isNull);

      await container.read(activeProviderProvider.notifier).set(rift);
      expect(
        container.read(libraryProvider).category,
        LibraryCategory.watching,
      );
      expect(storage.nativeSelectedCategory, 'pinned');
      expect(storage.getString('animerift_library_anime_category'), isNull);

      await container.read(activeProviderProvider.notifier).set(native);
      expect(
        container.read(libraryProvider).category,
        LibraryCategory.planToWatch,
      );
      expect(storage.nativeSelectedCategory, 'pinned');
    },
  );

  test(
    'Rift category selection preserves the native category and list',
    () async {
      final storage = _Storage();
      final account = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: SecureTokenStorage(storage),
      );
      await ProviderLocalLibrary(storage, animeRiftProviderId).setCategory(
        MultimediaItem(
          title: 'Rift Watching',
          url: 'same',
          posterUrl: '',
          provider: animeRiftProviderId,
        ),
        LibraryCategory.watching,
      );
      final native = _Source('com.fares669.animewitcher.native');
      final rift = _Source(animeRiftProviderId);
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          activeProviderProvider.overrideWith(() => _Active(native)),
        ],
      );
      addTearDown(container.dispose);

      expect(
        (container.read(libraryProvider) as LibrarySuccess).items.single.title,
        'Native Completed',
      );
      await container.read(activeProviderProvider.notifier).set(rift);
      await container
          .read(libraryProvider.notifier)
          .select(LibraryMediaKind.anime, LibraryCategory.watching);
      expect(storage.nativeSelectedCategory, 'completed');
      expect(
        (container.read(libraryProvider) as LibrarySuccess).items.single.title,
        'Rift Watching',
      );

      await container
          .read(libraryProvider.notifier)
          .selectCategory(LibraryCategory.favorite);
      expect(storage.nativeSelectedCategory, 'completed');
      await container.read(activeProviderProvider.notifier).set(native);
      expect(
        container.read(libraryProvider).category,
        LibraryCategory.completed,
      );
      expect(
        (container.read(libraryProvider) as LibrarySuccess).items.single.title,
        'Native Completed',
      );
      await container.read(activeProviderProvider.notifier).set(rift);
      expect(
        container.read(libraryProvider).category,
        LibraryCategory.favorite,
      );

      await container
          .read(libraryProvider.notifier)
          .selectMediaKind(LibraryMediaKind.manga);
      expect(
        container.read(libraryProvider).category,
        LibraryCategory.completed,
      );
      await container
          .read(libraryProvider.notifier)
          .selectMediaKind(LibraryMediaKind.anime);
      expect(
        container.read(libraryProvider).category,
        LibraryCategory.favorite,
      );
      expect(storage.nativeSelectedCategory, 'completed');
    },
  );
}
