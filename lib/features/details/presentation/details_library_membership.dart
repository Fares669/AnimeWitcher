import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/account/account_providers.dart';
import '../../../core/account/anime3rb_account_service.dart';
import '../../../core/account/witanime_account_service.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/providers/anime3rb_provider.dart';
import '../../../core/extensions/providers/witanime_provider.dart';
import '../../../core/storage/anime3rb_library_service.dart';
import '../../../core/storage/library_category.dart';
import '../../../core/storage/witanime_library_service.dart';
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
    String? aw;
    String? wt;
    String? a3;
    try {
      aw = ref.read(animeWitcherAccountServiceProvider).accountUid;
    } catch (_) {}
    try {
      wt = ref.read(witanimeAccountServiceProvider).accountId;
    } catch (_) {}
    try {
      a3 = ref.read(anime3rbAccountServiceProvider).accountId;
    } catch (_) {}
    if (aw == null && wt == null && a3 == null) return null;
    return '${aw ?? ''}|${wt ?? ''}|${a3 ?? ''}';
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
        LibraryMembership? remote;
        if (item.provider == WitanimeProvider.id) {
          final wtAccount = ref.read(witanimeAccountServiceProvider);
          if (wtAccount.isSignedIn) {
            final wtRemote = await ref
                .read(witanimeLibraryServiceProvider)
                .fetchMembership(item);
            if (!mounted || request != _libraryRequest) return;
            final awCategory = ref
                .read(libraryProvider.notifier)
                .localOnlyAnimeWitcherCategory(item.url);
            if (wtRemote != null) {
              remote = (
                category: wtRemote.category ?? awCategory,
                favorite: wtRemote.favorite,
              );
            }
          }
        } else if (item.provider == Anime3rbProvider.id) {
          final a3Account = ref.read(anime3rbAccountServiceProvider);
          if (a3Account.isSignedIn) {
            final a3Remote = await ref
                .read(anime3rbLibraryServiceProvider)
                .fetchMembership(item);
            if (!mounted || request != _libraryRequest) return;
            if (a3Remote != null) {
              remote = a3Remote;
            }
          }
        }
        if (remote == null) {
          final account = ref.read(animeWitcherAccountServiceProvider);
          remote = item.contentType == MultimediaContentType.manga
              ? await account.fetchMangaLibraryMembership(item)
              : await account.fetchAnimeLibraryMembership(item.url);
        }
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
    ref.listen(witanimeAccountRevisionProvider, (_, _) {
      if (_libraryOwner != _activeLibraryOwner) {
        setState(scheduleLibraryRead);
      }
    });
    ref.listen(anime3rbAccountRevisionProvider, (_, _) {
      if (_libraryOwner != _activeLibraryOwner) {
        setState(scheduleLibraryRead);
      }
    });
  }
}
