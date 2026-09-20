import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/library_auth.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

final class _LibraryStorage extends MemoryStorageService {
  int addCalls = 0;

  @override
  String? getString(String key) => null;

  @override
  String getSelectedLibraryCategory() => 'watching';

  @override
  List<MultimediaItem> getLibraryItems({String? category}) =>
      const <MultimediaItem>[];

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
    addCalls += 1;
  }

  @override
  bool isLibraryItemFavorite(String url) => false;

  @override
  String? getLibraryItemCategory(String url) => null;
}

void main() {
  test('signed-out manga mutations require the AnimeWitcher account', () async {
    final storage = _LibraryStorage();
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: SecureTokenStorage(storage),
    );
    final container = ProviderContainer(
      overrides: <Override>[
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(account),
      ],
    );
    addTearDown(container.dispose);

    final manga = MultimediaItem(
      title: 'Manga',
      url: 'https://animewitcher.com/manga/m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: AnimeWitcherAccountService.animeWitcherProvider,
    );

    await expectLater(
      container.read(libraryProvider.notifier).addItem(manga),
      throwsA(isA<LibrarySignInRequiredException>()),
    );
    expect(storage.addCalls, 0);
  });
}
