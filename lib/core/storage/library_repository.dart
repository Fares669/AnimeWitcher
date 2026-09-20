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
    VoidCallback? onLocalChanged,
  }) async {
    final target = category ?? getSelectedCategory();
    if (target == LibraryCategory.favorite) {
      await setFavorite(item, true);
      return;
    }
    final isManga = item.contentType == MultimediaContentType.manga;
    if (!isManga &&
        target == LibraryCategory.completed &&
        item.status != ShowStatus.completed) {
      return;
    }
    if (!isManga &&
        target == LibraryCategory.watching &&
        item.isNotYetAired) {
      return;
    }

    final previousItem = isManga ? _findItem(item.url) : null;
    final previousCategory = isManga ? getItemCategory(item.url) : null;
    final previousFavorite = isManga ? isFavorite(item.url) : false;
    if (isManga) _requireMangaCloudSession();

    await _storageService.addToLibrary(item, category: target.storageKey);
    onLocalChanged?.call();
    if (isManga) {
      try {
        await _accountService.saveMangaLibraryItem(
          item,
          target,
          favorite: _storageService.isLibraryItemFavorite(item.url),
        );
      } catch (_) {
        await _restoreMangaLocal(
          item: previousItem ?? item,
          existed: previousItem != null,
          category: previousCategory,
          favorite: previousFavorite,
        );
        onLocalChanged?.call();
        rethrow;
      }
      return;
    }
    _syncInBackground(
      _accountService.saveLibraryItem(
        item,
        target,
        favorite: _storageService.isLibraryItemFavorite(item.url),
      ),
      'save library item',
    );
  }

  Future<void> moveToCategory(
    String url,
    LibraryCategory category, {
    VoidCallback? onLocalChanged,
  }) async {
    if (category == LibraryCategory.favorite) {
      final item = _findItem(url);
      if (item != null) await setFavorite(item, true);
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
    final previousCategory = isManga ? getItemCategory(url) : null;
    final previousFavorite = isManga ? isFavorite(url) : false;
    if (isManga) _requireMangaCloudSession();

    await _storageService.setLibraryItemCategory(url, category.storageKey);
    onLocalChanged?.call();
    if (item != null && isManga) {
      try {
        await _accountService.saveMangaLibraryItem(
          item,
          category,
          favorite: _storageService.isLibraryItemFavorite(url),
        );
      } catch (_) {
        await _restoreMangaLocal(
          item: item,
          existed: true,
          category: previousCategory,
          favorite: previousFavorite,
        );
        onLocalChanged?.call();
        rethrow;
      }
      return;
    }
    if (item != null) {
      _syncInBackground(
        _accountService.saveLibraryItem(
          item,
          category,
          favorite: _storageService.isLibraryItemFavorite(url),
        ),
        'move library item',
      );
    }
  }

  Future<void> clearCategory(
    String url, {
    VoidCallback? onLocalChanged,
  }) async {
    final item = _findItem(url);
    final favorite = _storageService.isLibraryItemFavorite(url);
    final previousCategory = getItemCategory(url);
    final isManga = item?.contentType == MultimediaContentType.manga;
    if (isManga) _requireMangaCloudSession();

    await _storageService.setLibraryItemCategory(url, null);
    onLocalChanged?.call();
    if (item == null) return;
    if (isManga) {
      try {
        if (favorite) {
          await _accountService.saveMangaLibraryItem(
            item,
            null,
            favorite: true,
          );
        } else {
          await _accountService.removeMangaLibraryItem(url);
        }
      } catch (_) {
        await _restoreMangaLocal(
          item: item,
          existed: true,
          category: previousCategory,
          favorite: favorite,
        );
        onLocalChanged?.call();
        rethrow;
      }
      return;
    }
    if (favorite) {
      _syncInBackground(
        _accountService.saveLibraryItem(item, null, favorite: true),
        'clear library category',
      );
    } else {
      _syncInBackground(
        _accountService.removeLibraryItem(url),
        'remove library item',
      );
    }
  }

  Future<void> setFavorite(
    MultimediaItem item,
    bool favorite, {
    VoidCallback? onLocalChanged,
  }) async {
    final category = getItemCategory(item.url);
    final isManga = item.contentType == MultimediaContentType.manga;
    final previousItem = isManga ? _findItem(item.url) : null;
    final previousFavorite = isManga ? isFavorite(item.url) : false;
    if (isManga) _requireMangaCloudSession();

    await _storageService.addToLibrary(item, favorite: favorite);
    onLocalChanged?.call();
    if (isManga) {
      try {
        if (!favorite && category == null) {
          await _accountService.removeMangaLibraryItem(item.url);
        } else {
          await _accountService.saveMangaLibraryItem(
            item,
            category,
            favorite: favorite,
          );
        }
      } catch (_) {
        await _restoreMangaLocal(
          item: previousItem ?? item,
          existed: previousItem != null,
          category: category,
          favorite: previousFavorite,
        );
        onLocalChanged?.call();
        rethrow;
      }
      return;
    }
    if (!favorite && category == null) {
      _syncInBackground(
        _accountService.removeLibraryItem(item.url),
        'remove favorite-only library item',
      );
      return;
    }
    _syncInBackground(
      _accountService.saveLibraryItem(item, category, favorite: favorite),
      favorite ? 'save favorite' : 'remove favorite',
    );
  }

  Future<void> removeFromLibrary(
    String url, {
    VoidCallback? onLocalChanged,
  }) async {
    final item = _findItem(url);
    final isManga = item?.contentType == MultimediaContentType.manga;
    final previousCategory = isManga ? getItemCategory(url) : null;
    final previousFavorite = isManga ? isFavorite(url) : false;
    if (isManga) _requireMangaCloudSession();

    await _storageService.removeFromLibrary(url);
    onLocalChanged?.call();
    if (item != null && isManga) {
      try {
        await _accountService.removeMangaLibraryItem(url);
      } catch (_) {
        await _restoreMangaLocal(
          item: item,
          existed: true,
          category: previousCategory,
          favorite: previousFavorite,
        );
        onLocalChanged?.call();
        rethrow;
      }
      return;
    }
    _syncInBackground(
      _accountService.removeLibraryItem(url),
      'remove library item',
    );
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

  Future<void> _restoreMangaLocal({
    required MultimediaItem item,
    required bool existed,
    required LibraryCategory? category,
    required bool favorite,
  }) async {
    if (!existed) {
      await _storageService.removeFromLibrary(item.url);
      return;
    }
    await _storageService.addToLibrary(
      item,
      category: category?.storageKey,
      replaceCategory: true,
      favorite: favorite,
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
