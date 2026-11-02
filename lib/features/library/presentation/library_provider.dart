import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:animewitcher/core/account/account_providers.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/storage/library_category.dart';
import '../../../../core/storage/library_repository.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/storage/provider_local_library.dart';
import '../../../../core/extensions/extension_manager.dart';

import './library_auth.dart';
import './library_state.dart';
import './library_media_kind.dart';

part 'library_provider.g.dart';

@Riverpod(keepAlive: true)
class Library extends _$Library {
  @override
  LibraryState build() {
    ref.watch(accountDataRevisionProvider);
    final activeProvider = ref.watch(activeProviderProvider);
    final repository = ref.read(libraryRepositoryProvider);
    final category = repository.getSelectedCategory();
    final mediaKind = LibraryMediaKind.fromStorageKey(
      ref.read(storageServiceProvider).getString('library_media_kind'),
    );
    final items = filterLibraryItemsByKind(
      activeProvider?.packageName == animeRiftProviderId &&
              mediaKind == LibraryMediaKind.anime
          ? _local().items(category)
          : repository.getLibraryItems(category: category),
      mediaKind,
    );
    return items.isEmpty
        ? LibraryEmpty(category, mediaKind)
        : LibrarySuccess(items, category, mediaKind);
  }

  LibraryCategory get selectedCategory => state.category;
  LibraryMediaKind get selectedMediaKind => state.mediaKind;

  LibraryState refresh({
    LibraryCategory? category,
    LibraryMediaKind? mediaKind,
  }) {
    final repository = ref.read(libraryRepositoryProvider);
    final selected = category ?? state.category;
    final selectedKind = mediaKind ?? state.mediaKind;
    final items = filterLibraryItemsByKind(
      ref.read(activeProviderProvider)?.packageName == animeRiftProviderId &&
              selectedKind == LibraryMediaKind.anime
          ? _local().items(selected)
          : repository.getLibraryItems(category: selected),
      selectedKind,
    );
    state = items.isEmpty
        ? LibraryEmpty(selected, selectedKind)
        : LibrarySuccess(items, selected, selectedKind);
    return state;
  }

  Future<void> selectCategory(LibraryCategory category) async {
    final repository = ref.read(libraryRepositoryProvider);
    await repository.setSelectedCategory(category);
    refresh(category: category);
  }

  /// Picks [category] of the [mediaKind] half at once, as the side list does.
  Future<void> select(
    LibraryMediaKind mediaKind,
    LibraryCategory category,
  ) async {
    await ref
        .read(storageServiceProvider)
        .setString('library_media_kind', mediaKind.storageKey);
    await ref.read(libraryRepositoryProvider).setSelectedCategory(category);
    refresh(category: category, mediaKind: mediaKind);
  }

  Future<void> selectMediaKind(LibraryMediaKind mediaKind) async {
    await ref
        .read(storageServiceProvider)
        .setString('library_media_kind', mediaKind.storageKey);
    refresh(mediaKind: mediaKind);
  }

  Future<void> addItem(MultimediaItem item, {LibraryCategory? category}) async {
    if (item.provider == animeRiftProviderId &&
        item.contentType != MultimediaContentType.manga) {
      final selected = category ?? state.category;
      if (selected != LibraryCategory.favorite &&
          !selected.isAssignableTo(item)) {
        return;
      }
      if (selected == LibraryCategory.favorite) {
        await _local().setFavorite(item, true);
      } else {
        await _local().setCategory(item, selected);
      }
      refresh();
      return;
    }
    _requireSignedIn();
    final repository = ref.read(libraryRepositoryProvider);
    await repository.addToLibrary(
      item,
      category: category ?? state.category,
      onLocalChanged: refresh,
    );
    refresh();
  }

  Future<void> clearItemCategory(
    String url, {
    bool manga = false,
    String? providerId,
  }) async {
    if (!manga && providerId == animeRiftProviderId) {
      await _local().clearCategory(url);
      refresh();
      return;
    }
    _requireSignedIn();
    final repository = ref.read(libraryRepositoryProvider);
    await repository.clearCategory(url, onLocalChanged: refresh);
    refresh();
  }

  Future<void> setFavorite(MultimediaItem item, bool favorite) async {
    if (item.provider == animeRiftProviderId &&
        item.contentType != MultimediaContentType.manga) {
      await _local().setFavorite(item, favorite);
      refresh();
      return;
    }
    _requireSignedIn();
    final repository = ref.read(libraryRepositoryProvider);
    await repository.setFavorite(item, favorite, onLocalChanged: refresh);
    refresh();
  }

  void _requireSignedIn() {
    requireLibrarySignIn(
      ref.read(animeWitcherAccountServiceProvider).isSignedIn,
    );
  }

  ProviderLocalLibrary _local() => ProviderLocalLibrary(
    ref.read(storageServiceProvider),
    animeRiftProviderId,
  );

  bool isFavorite(String url, {String? providerId}) {
    if (providerId == animeRiftProviderId) return _local().isFavorite(url);
    final repository = ref.read(libraryRepositoryProvider);
    return repository.isFavorite(url);
  }

  LibraryCategory? itemCategory(String url, {String? providerId}) {
    if (providerId == animeRiftProviderId) return _local().category(url);
    final repository = ref.read(libraryRepositoryProvider);
    return repository.getItemCategory(url);
  }
}
