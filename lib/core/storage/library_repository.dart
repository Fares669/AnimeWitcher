import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../account/account_providers.dart';
import '../account/animewitcher_account_service.dart';
import '../domain/entity/multimedia_item.dart';
import 'library_category.dart';
import 'storage_service.dart';

part 'library_repository.g.dart';

@Riverpod(keepAlive: true)
LibraryRepository libraryRepository(Ref ref) {
  return LibraryRepository(
    ref.watch(storageServiceProvider),
    ref.watch(animeWitcherAccountServiceProvider),
  );
}

class LibraryRepository {
  final StorageService _storageService;
  final AnimeWitcherAccountService _accountService;
  LibraryRepository(this._storageService, this._accountService);

  Future<void> addToLibrary(
    MultimediaItem item, {
    LibraryCategory? category,
    LibraryMembership? membership,
    VoidCallback? onLocalChanged,
  }) async {
    final target = category ?? getSelectedCategory();
    if (target == LibraryCategory.favorite) {
      await setFavorite(
        item,
        true,
        membership: membership,
        onLocalChanged: onLocalChanged,
      );
      return;
    }
    final isManga = item.contentType == MultimediaContentType.manga;
    if (!isManga &&
        target == LibraryCategory.completed &&
        item.status != ShowStatus.completed) {
      return;
    }
    if (!isManga && target == LibraryCategory.watching && item.isNotYetAired) {
      return;
    }

    if (isManga) _requireMangaCloudSession();
    await _storageService.addToLibrary(
      item,
      category: target.storageKey,
      favorite: membership?.favorite,
    );
    _saveNative(item, (
      category: target,
      favorite: _storageService.isLibraryItemFavorite(item.url),
    ), changeFavorite: membership == null ? null : false);
    onLocalChanged?.call();
  }

  Future<void> moveToCategory(
    String url,
    LibraryCategory category, {
    VoidCallback? onLocalChanged,
  }) async {
    if (category == LibraryCategory.favorite) {
      final item = _findItem(url);
      if (item != null) {
        await setFavorite(item, true, onLocalChanged: onLocalChanged);
      }
      return;
    }

    final item = _findItem(url);
    final isManga = item?.contentType == MultimediaContentType.manga;
    if (!isManga &&
        category == LibraryCategory.completed &&
        item != null &&
        item.status != ShowStatus.completed) {
      return;
    }
    if (!isManga &&
        category == LibraryCategory.watching &&
        item != null &&
        item.isNotYetAired) {
      return;
    }
    if (isManga) _requireMangaCloudSession();
    await _storageService.setLibraryItemCategory(url, category.storageKey);
    if (item != null) {
      _saveNative(item, (
        category: category,
        favorite: _storageService.isLibraryItemFavorite(url),
      ));
    }
    onLocalChanged?.call();
  }

  Future<void> clearCategory(
    String url, {
    bool manga = false,
    VoidCallback? onLocalChanged,
  }) async {
    final isManga =
        manga || _findItem(url)?.contentType == MultimediaContentType.manga;
    if (isManga) _requireMangaCloudSession();
    await _storageService.setLibraryItemCategory(url, null);
    _deleteNative(url, manga: isManga, keepFavorite: true);
    onLocalChanged?.call();
  }

  Future<void> setFavorite(
    MultimediaItem item,
    bool favorite, {
    LibraryMembership? membership,
    VoidCallback? onLocalChanged,
  }) async {
    final category = membership == null
        ? getItemCategory(item.url)
        : membership.category;
    final isManga = item.contentType == MultimediaContentType.manga;
    if (isManga) _requireMangaCloudSession();
    await _storageService.addToLibrary(
      item,
      category: membership?.category?.storageKey,
      replaceCategory: membership != null,
      favorite: favorite,
    );
    if (membership == null && !favorite && category == null) {
      _deleteNative(item.url, manga: isManga);
    } else {
      _saveNative(item, (
        category: category,
        favorite: favorite,
      ), changeFavorite: membership == null ? null : true);
    }
    onLocalChanged?.call();
  }

  Future<void> removeFromLibrary(
    String url, {
    VoidCallback? onLocalChanged,
  }) async {
    final item = _findItem(url);
    final isManga = item?.contentType == MultimediaContentType.manga;
    if (isManga) _requireMangaCloudSession();
    await _storageService.removeFromLibrary(url);
    _deleteNative(url, manga: isManga);
    onLocalChanged?.call();
  }

  bool isInLibrary(String url) {
    return _storageService.isInLibrary(url);
  }

  bool isFavorite(String url) {
    return _storageService.isLibraryItemFavorite(url);
  }

  LibraryCategory? getItemCategory(String url) {
    final value = _storageService.getLibraryItemCategory(url);
    if (value == null) return null;
    final category = LibraryCategory.fromStorageKey(value);
    return category.isPrimary ? category : null;
  }

  List<MultimediaItem> getLibraryItems({LibraryCategory? category}) {
    return _storageService.getLibraryItems(category: category?.storageKey);
  }

  ({List<MultimediaItem> items, int total}) getLocalShelf({
    required LibraryCategory category,
    required bool manga,
    required int limit,
  }) => _storageService.getLocalLibraryShelf(
    category: category.storageKey,
    manga: manga,
    limit: limit,
  );

  int getLibraryItemUpdatedAt(String url) {
    return _storageService.getLibraryItemUpdatedAt(url);
  }

  Future<void> setSelectedCategory(LibraryCategory category) async {
    await _storageService.setSelectedLibraryCategory(category.storageKey);
  }

  LibraryCategory getSelectedCategory() {
    return LibraryCategory.fromStorageKey(
      _storageService.getSelectedLibraryCategory(),
    );
  }

  MultimediaItem? _findItem(String url) {
    for (final item in _storageService.getLibraryItems()) {
      if (item.url == url) return item;
    }
    return null;
  }

  void _requireMangaCloudSession() {
    if (!_accountService.isSignedIn) {
      throw StateError(
        'AnimeWitcher account is required for Manga library mutations.',
      );
    }
  }

  void _saveNative(
    MultimediaItem item,
    LibraryMembership membership, {
    bool? changeFavorite,
  }) {
    final manga = item.contentType == MultimediaContentType.manga;
    final operation = changeFavorite != null
        ? _accountService.saveLibraryField(
            item,
            membership,
            changeFavorite: changeFavorite,
          )
        : manga
        ? _accountService.saveMangaLibraryItem(
            item,
            membership.category,
            favorite: membership.favorite,
          )
        : _accountService.saveLibraryItem(
            item,
            membership.category,
            favorite: membership.favorite,
          );
    _syncInBackground(operation, 'save library item');
  }

  void _deleteNative(
    String url, {
    required bool manga,
    bool keepFavorite = false,
  }) {
    _syncInBackground(
      manga
          ? _accountService.removeMangaLibraryItem(
              url,
              keepFavorite: keepFavorite,
            )
          : _accountService.removeLibraryItem(url, keepFavorite: keepFavorite),
      'remove library item',
    );
  }

  void _syncInBackground(Future<void> operation, String label) {
    unawaited(
      operation.catchError((Object error) {
        if (kDebugMode) {
          debugPrint('[AnimeWitcherAccount] Could not $label: $error');
        }
      }),
    );
  }
}
