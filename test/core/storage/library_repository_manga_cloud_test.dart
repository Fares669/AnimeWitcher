import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/library_repository.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

final class _LibraryStorage extends StorageService {
  final Map<String, MultimediaItem> _items = <String, MultimediaItem>{};
  final Map<String, String?> _categories = <String, String?>{};
  final Map<String, bool> _favorites = <String, bool>{};

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
    _items[item.url] = item;
    if (category != null || replaceCategory) {
      _categories[item.url] = category;
    }
    if (favorite != null) _favorites[item.url] = favorite;
  }

  @override
  Future<void> setLibraryItemCategory(String url, String? category) async {
    if (!_items.containsKey(url)) return;
    _categories[url] = category;
    if (category == null && !(_favorites[url] ?? false)) {
      _items.remove(url);
      _categories.remove(url);
      _favorites.remove(url);
    }
  }

  @override
  Future<void> removeFromLibrary(String url) async {
    _items.remove(url);
    _categories.remove(url);
    _favorites.remove(url);
  }

  @override
  bool isInLibrary(String url) => _items.containsKey(url);

  @override
  bool isLibraryItemFavorite(String url) => _favorites[url] ?? false;

  @override
  String? getLibraryItemCategory(String url) => _categories[url];

  @override
  List<MultimediaItem> getLibraryItems({String? category}) {
    if (category == null) return _items.values.toList(growable: false);
    return _items.values
        .where((item) => _categories[item.url] == category)
        .toList(growable: false);
  }

  @override
  String getSelectedLibraryCategory() => LibraryCategory.watching.storageKey;
}

final class _FailingMangaAccountService extends AnimeWitcherAccountService {
  _FailingMangaAccountService(StorageService storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  @override
  Future<void> saveMangaLibraryItem(
    MultimediaItem item,
    LibraryCategory? category, {
    bool? favorite,
  }) async {
    throw StateError('server write failed');
  }

  @override
  Future<void> removeMangaLibraryItem(String url) async {
    throw StateError('server delete failed');
  }
}

void main() {
  const manga = MultimediaItem(
    title: 'Manga',
    url: 'https://animewitcher.com/manga/m1',
    posterUrl: '',
    contentType: MultimediaContentType.manga,
    provider: AnimeWitcherAccountService.animeWitcherProvider,
  );

  test('failed manga cloud add rolls local state back and surfaces error', () async {
    final storage = _LibraryStorage();
    final repository = LibraryRepository(
      storage,
      _FailingMangaAccountService(storage),
    );

    await expectLater(
      repository.addToLibrary(manga, category: LibraryCategory.watching),
      throwsA(isA<StateError>()),
    );

    expect(storage.isInLibrary(manga.url), isFalse);
  });

  test('failed manga cloud delete restores the previous local row', () async {
    final storage = _LibraryStorage();
    await storage.addToLibrary(
      manga,
      category: LibraryCategory.watching.storageKey,
      favorite: true,
    );
    final repository = LibraryRepository(
      storage,
      _FailingMangaAccountService(storage),
    );

    await expectLater(
      repository.removeFromLibrary(manga.url),
      throwsA(isA<StateError>()),
    );

    expect(storage.isInLibrary(manga.url), isTrue);
    expect(
      storage.getLibraryItemCategory(manga.url),
      LibraryCategory.watching.storageKey,
    );
    expect(storage.isLibraryItemFavorite(manga.url), isTrue);
  });
}
