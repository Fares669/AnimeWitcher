import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/storage/library_category.dart';
import '../../library/presentation/library_provider.dart';

mixin DetailsLibraryMembership<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  MultimediaItem get libraryItem;

  LibraryMembership? _serverMembership;
  ({LibraryCategory? value})? _editedCategory;
  bool? _editedFavorite;
  bool _editingLibrary = false;
  int _libraryRequest = 0;
  String? _libraryOwner;

  String? get _activeLibraryOwner {
    try {
      return ref.read(animeWitcherAccountServiceProvider).accountUid;
    } catch (_) {
      return null;
    }
  }

  LibraryMembership get libraryMembership {
    final item = libraryItem;
    final library = ref.read(libraryProvider.notifier);
    final sameOwner = _libraryOwner == _activeLibraryOwner;
    final remote = sameOwner ? _serverMembership : null;
    final editedCategory = sameOwner ? _editedCategory : null;
    final editedFavorite = sameOwner ? _editedFavorite : null;
    return (
      category: editedCategory != null
          ? editedCategory.value
          : remote == null
          ? library.itemCategory(
              item.url,
              providerId: item.provider,
              manga: item.contentType == MultimediaContentType.manga,
            )
          : remote.category,
      favorite:
          editedFavorite ??
          (remote == null
              ? library.isFavorite(item.url, providerId: item.provider)
              : remote.favorite),
    );
  }

  void scheduleLibraryRead() {
    final request = ++_libraryRequest;
    _libraryOwner = _activeLibraryOwner;
    _serverMembership = null;
    _editedCategory = null;
    _editedFavorite = null;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || request != _libraryRequest) return;
      try {
        final item = libraryItem;
        final account = ref.read(animeWitcherAccountServiceProvider);
        final remote = item.contentType == MultimediaContentType.manga
            ? await account.fetchMangaLibraryMembership(item)
            : await account.fetchAnimeLibraryMembership(item.url);
        if (!mounted || request != _libraryRequest || remote == null) return;
        setState(() {
          _libraryOwner = _activeLibraryOwner;
          _serverMembership = remote;
        });
      } catch (_) {
        // Offline or incomplete server responses leave the local state usable.
      }
    });
  }

  Future<void> editLibrary(
    LibraryMembership next,
    Future<void> Function() apply, {
    required bool favorite,
  }) async {
    if (!mounted || _editingLibrary) return;
    final previousCategory = _editedCategory;
    final previousFavorite = _editedFavorite;
    final request = _libraryRequest;
    _editingLibrary = true;
    setState(() {
      if (favorite) {
        _editedFavorite = next.favorite;
      } else {
        _editedCategory = (value: next.category);
      }
    });
    try {
      await apply();
    } catch (_) {
      if (mounted && request == _libraryRequest) {
        setState(() {
          _editedCategory = previousCategory;
          _editedFavorite = previousFavorite;
        });
      }
      rethrow;
    } finally {
      _editingLibrary = false;
    }
  }

  void listenToLibraryAccount() {
    ref.listen(accountDataRevisionProvider, (_, _) {
      if (_libraryOwner != _activeLibraryOwner) {
        setState(scheduleLibraryRead);
      }
    });
  }
}
