import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/library_repository.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Storage extends StorageService {
  final values = <String, String>{'legacy': 'untouched'};
  final nativeItems = <String, MultimediaItem>{};
  int nativeWrites = 0;

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
  String getSelectedLibraryCategory() => LibraryCategory.watching.storageKey;

  @override
  Future<void> addToLibrary(
    MultimediaItem item, {
    String? category,
    bool replaceCategory = false,
    bool? favorite,
    int? updatedAt,
    String? syncedAccountUid,
    int? syncedAt,
  }) async {
    nativeWrites++;
    nativeItems[item.url] = item;
  }

  @override
  List<MultimediaItem> getLibraryItems({String? category}) =>
      nativeItems.values.toList(growable: false);

  @override
  bool isInLibrary(String url) => nativeItems.containsKey(url);

  @override
  bool isLibraryItemFavorite(String url) => false;

  @override
  String? getLibraryItemCategory(String url) => null;

  @override
  Future<void> setLibraryItemCategory(String url, String? category) async {
    nativeWrites++;
  }

  @override
  Future<void> removeFromLibrary(String url) async {
    nativeWrites++;
    nativeItems.remove(url);
  }
}

final class _Account extends AnimeWitcherAccountService {
  _Account(_Storage storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  int cloudWrites = 0;

  @override
  Future<void> saveLibraryItem(
    MultimediaItem item,
    LibraryCategory? category, {
    bool? favorite,
    List<FirestoreDocument>? knownFavorites,
  }) async {
    cloudWrites++;
  }
}

void main() {
  test(
    'Rift library writes never touch native records or cloud sync',
    () async {
      final storage = _Storage();
      final account = _Account(storage);
      final repository = LibraryRepository(storage, account);
      const url = 'https://animewitcher.com/watch/same-id';
      final native = MultimediaItem(title: 'Native', url: url, posterUrl: '');
      final rift = MultimediaItem(
        title: 'Rift',
        url: url,
        posterUrl: '',
        provider: animeRiftProviderId,
      );
      storage.nativeItems[url] = native;

      await repository.addToLibrary(
        rift,
        category: LibraryCategory.planToWatch,
      );
      await repository.setFavorite(rift, true);

      final local = ProviderLocalLibrary(storage, animeRiftProviderId);
      expect(local.category(url), LibraryCategory.planToWatch);
      expect(local.isFavorite(url), isTrue);
      expect(
        repository.isFavorite(url, providerId: animeRiftProviderId),
        isTrue,
      );
      expect(
        repository.getItemCategory(url, providerId: animeRiftProviderId),
        LibraryCategory.planToWatch,
      );
      expect(
        repository
            .getLibraryItems(providerId: animeRiftProviderId)
            .single
            .title,
        'Rift',
      );
      expect(repository.getLibraryItems().single.title, 'Native');
      expect(storage.nativeItems[url]!.title, 'Native');
      expect(storage.nativeWrites, 0);
      expect(account.cloudWrites, 0);
      expect(storage.values['legacy'], 'untouched');
    },
  );

  test(
    'Rift category moves and removal preserve colliding native entry',
    () async {
      final storage = _Storage();
      final account = _Account(storage);
      final repository = LibraryRepository(storage, account);
      const url = 'https://animewitcher.com/watch/same-id';
      storage.nativeItems[url] = MultimediaItem(
        title: 'Native',
        url: url,
        posterUrl: '',
      );
      final rift = MultimediaItem(
        title: 'Rift',
        url: url,
        posterUrl: '',
        provider: animeRiftProviderId,
      );

      await repository.addToLibrary(
        rift,
        category: LibraryCategory.planToWatch,
      );
      await repository.setFavorite(rift, true);
      await repository.moveToCategory(
        url,
        LibraryCategory.continueLater,
        providerId: animeRiftProviderId,
      );
      final restarted = LibraryRepository(storage, account);
      expect(
        restarted.getItemCategory(url, providerId: animeRiftProviderId),
        LibraryCategory.continueLater,
      );
      await restarted.clearCategory(url, providerId: animeRiftProviderId);
      expect(
        restarted.isFavorite(url, providerId: animeRiftProviderId),
        isTrue,
      );
      expect(
        restarted.getItemCategory(url, providerId: animeRiftProviderId),
        isNull,
      );
      await restarted.removeFromLibrary(url, providerId: animeRiftProviderId);
      expect(
        restarted.isInLibrary(url, providerId: animeRiftProviderId),
        isFalse,
      );
      expect(restarted.isInLibrary(url), isTrue);
      expect(storage.nativeItems[url]!.title, 'Native');
      expect(storage.nativeWrites, 0);
      expect(account.cloudWrites, 0);
    },
  );

  test('Rift routing is provider-based even for manga content', () async {
    final storage = _Storage();
    final account = _Account(storage);
    final repository = LibraryRepository(storage, account);
    const url = 'https://animewitcher.com/manga/same-id';
    final rift = MultimediaItem(
      title: 'Rift Manga-shaped Item',
      url: url,
      posterUrl: '',
      provider: animeRiftProviderId,
      contentType: MultimediaContentType.manga,
    );

    await repository.addToLibrary(
      rift,
      category: LibraryCategory.planToWatch,
    );
    await repository.setFavorite(rift, true);

    expect(
      repository.getItemCategory(url, providerId: animeRiftProviderId),
      LibraryCategory.planToWatch,
    );
    expect(repository.isFavorite(url, providerId: animeRiftProviderId), isTrue);
    expect(storage.nativeWrites, 0);
    expect(storage.nativeItems, isEmpty);
    expect(account.cloudWrites, 0);
  });
}
