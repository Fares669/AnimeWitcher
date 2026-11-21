import 'dart:async';
import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/app_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

final class _Storage extends MemoryStorageService {
  bool highQualityPosters = false;

  @override
  bool isHighQualityPostersEnabled() => highQualityPosters;

  final Map<String, MultimediaItem> library = <String, MultimediaItem>{};
  final Map<String, String?> categories = <String, String?>{};
  final Map<String, bool> favorites = <String, bool>{};
  final Map<String, int> updatedAt = <String, int>{};
  final Map<String, int> syncedAt = <String, int>{};
  final Map<String, String?> syncedUid = <String, String?>{};

  @override
  String? getString(String key) => settings[key] as String?;

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      settings.remove(key);
    } else {
      settings[key] = value;
    }
  }

  @override
  Future<void> remove(String key) async {
    settings.remove(key);
  }

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
    library[item.url] = item;
    if (replaceCategory || category != null) categories[item.url] = category;
    if (favorite != null) favorites[item.url] = favorite;
    this.updatedAt[item.url] =
        updatedAt ?? DateTime.now().millisecondsSinceEpoch;
    if (syncedAccountUid != null) syncedUid[item.url] = syncedAccountUid;
    if (syncedAt != null) this.syncedAt[item.url] = syncedAt;
  }

  @override
  List<MultimediaItem> getLibraryItems({String? category}) =>
      library.values.toList(growable: false);

  @override
  String? getLibraryItemCategory(String url) => categories[url];

  @override
  bool isLibraryItemFavorite(String url) => favorites[url] == true;

  @override
  int getLibraryItemUpdatedAt(String url) => updatedAt[url] ?? 0;

  @override
  int getLibraryItemSyncedAt(String url) => syncedAt[url] ?? 0;

  @override
  String? getLibraryItemSyncedAccountUid(String url) => syncedUid[url];

  @override
  Future<void> markLibraryItemSynced(
    String url, {
    required String accountUid,
    required int syncedAt,
  }) async {
    syncedUid[url] = accountUid;
    this.syncedAt[url] = syncedAt;
  }

  @override
  Future<void> removeFromLibrary(String url) async {
    library.remove(url);
    categories.remove(url);
    favorites.remove(url);
    updatedAt.remove(url);
    syncedAt.remove(url);
    syncedUid.remove(url);
  }

  @override
  List<Map<String, dynamic>> getContinueWatching() =>
      const <Map<String, dynamic>>[];

  @override
  List<Map<String, dynamic>> getWatchHistory() =>
      const <Map<String, dynamic>>[];
}

final class _SecureStorage extends SecureTokenStorage {
  _SecureStorage(super.storage);

  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

final class _ArrayTransform {
  const _ArrayTransform({
    required this.path,
    required this.field,
    required this.values,
    required this.append,
    required this.baseFields,
  });

  final String path;
  final String field;
  final List<dynamic> values;
  final bool append;
  final Map<String, dynamic> baseFields;
}

final class _Write {
  const _Write(this.path, this.fields, this.serverTimestampFields);

  final String path;
  final Map<String, dynamic> fields;
  final Set<String> serverTimestampFields;
}

final class _Firestore extends FirestoreRestClient {
  final List<_Write> writes = <_Write>[];
  final List<String> queries = <String>[];
  bool offline = false;
  String? failedCollection;
  final stageError = StateError('private token https://private.example/uid-1');
  final List<_ArrayTransform> arrayTransforms = <_ArrayTransform>[];
  bool failArrayTransforms = false;
  final List<String> deletes = <String>[];
  final Map<String, List<FirestoreDocument>> collections =
      <String, List<FirestoreDocument>>{};
  final Map<String, FirestoreDocument> documents =
      <String, FirestoreDocument>{};
  Completer<void>? blockDetails;
  Completer<void>? blockWrites;
  final List<String> detailRequests = <String>[];
  final List<List<String>> posterBatchRequests = <List<String>>[];
  final List<({bool manga, List<String> ids})> libraryBatchRequests =
      <({bool manga, List<String> ids})>[];
  bool failPosterBatch = false;
  bool failLibraryBatch = false;
  int countRequests = 0;

  @override
  Future<Map<String, Map<String, dynamic>>> fetchCatalogPosterFields(
    List<String> animeIds,
    String idToken,
  ) async {
    posterBatchRequests.add(List<String>.of(animeIds));
    if (failPosterBatch) throw StateError('poster endpoint unavailable');
    return {
      for (final id in animeIds)
        if (documents['anime_list/$id'] case final FirestoreDocument doc)
          id: doc.fields,
    };
  }

  @override
  Future<Map<String, Map<String, dynamic>>> fetchCatalogLibraryFields(
    List<String> ids,
    String idToken, {
    required bool manga,
  }) async {
    libraryBatchRequests.add((manga: manga, ids: List<String>.of(ids)));
    if (failLibraryBatch) throw StateError('library batch unavailable');
    final collection = manga ? 'manga_list' : 'anime_list';
    return {
      for (final id in ids)
        if (documents['$collection/$id'] case final FirestoreDocument doc)
          id: doc.fields,
    };
  }

  @override
  Future<void> setDocumentWithServerTimestamps(
    String path,
    Map<String, dynamic> fields,
    String idToken, {
    required Set<String> serverTimestampFields,
    bool merge = true,
  }) async {
    if (blockWrites != null) {
      await blockWrites!.future;
    }
    writes.add(
      _Write(
        path,
        Map<String, dynamic>.from(fields),
        Set<String>.from(serverTimestampFields),
      ),
    );
  }

  @override
  Future<void> deleteDocument(String path, String idToken) async {
    deletes.add(path);
    final collection = path.substring(0, path.lastIndexOf('/'));
    collections[collection]?.removeWhere((doc) => doc.path == path);
  }

  @override
  Future<FirestoreDocument?> findLibraryDocument(
    String collectionPath,
    String id,
    String token, {
    required bool favorite,
    bool manga = false,
  }) async {
    return collections[collectionPath]?.where((doc) {
      final ref = doc.fields['manga_doc_id'] ?? doc.fields['doc_ref'];
      return doc.id == id || ref == 'manga_list/$id';
    }).firstOrNull;
  }

  @override
  Future<List<FirestoreDocument>> queryOrderedDocuments(
    String collectionPath,
    String idToken, {
    String orderField = 'date',
    bool descending = true,
    int pageSize = 100,
  }) async {
    queries.add(collectionPath);
    if (offline) throw StateError('offline');
    return List<FirestoreDocument>.from(
      collections[collectionPath] ?? const <FirestoreDocument>[],
    );
  }

  final List<({String path, String? type, FirestoreDocument? cursor})>
  pageRequests = [];

  @override
  Future<List<FirestoreDocument>> queryLibraryDocumentsPage(
    String collectionPath,
    String idToken, {
    String? type,
    FirestoreDocument? startAfter,
    int limit = 30,
  }) async {
    pageRequests.add((path: collectionPath, type: type, cursor: startAfter));
    final docs = (collections[collectionPath] ?? [])
        .where((d) => type == null || d.fields['type'] == type)
        .toList();
    final start = startAfter == null
        ? 0
        : docs.indexWhere((d) => d.path == startAfter.path) + 1;
    return docs.skip(start).take(limit).toList();
  }

  @override
  Future<int> countLibraryDocuments(
    String collectionPath,
    String idToken, {
    String? type,
  }) async {
    countRequests++;
    return (collections[collectionPath] ?? [])
        .where((d) => type == null || d.fields['type'] == type)
        .length;
  }

  @override
  Future<void> transformArrayFieldValues(
    String path, {
    required String idToken,
    required String field,
    required Iterable<dynamic> values,
    required bool append,
    Map<String, dynamic> baseFields = const <String, dynamic>{},
  }) async {
    if (failArrayTransforms) {
      throw StateError('offline');
    }
    arrayTransforms.add(
      _ArrayTransform(
        path: path,
        field: field,
        values: values.toList(growable: false),
        append: append,
        baseFields: Map<String, dynamic>.from(baseFields),
      ),
    );
  }

  @override
  Future<List<FirestoreDocument>> listDocuments(
    String collectionPath,
    String idToken, {
    int pageSize = 100,
  }) async {
    if (collectionPath == failedCollection) throw stageError;
    return List<FirestoreDocument>.from(
      collections[collectionPath] ?? const <FirestoreDocument>[],
    );
  }

  @override
  Future<FirestoreDocument?> getDocument(String path, String idToken) async {
    detailRequests.add(path);
    if (blockDetails != null) await blockDetails!.future;
    return documents[path];
  }
}

Future<AnimeWitcherAccountService> _signedInService(
  _Firestore firestore, {
  _Storage? storage,
  AppDiagnostics? diagnostics,
}) async {
  final backing = storage ?? _Storage();
  final secure = _SecureStorage(backing);
  final session = AnimeWitcherSession(
    uid: 'uid-1',
    idToken: 'token',
    refreshToken: 'refresh',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    signInMethod: AnimeWitcherSignInMethod.email,
    email: 'reader@example.com',
  );
  const profile = AnimeWitcherProfile(
    documentId: 'profile-1',
    uid: 'uid-1',
    signInMethod: AnimeWitcherSignInMethod.email,
    email: 'reader@example.com',
    userName: 'Reader',
  );
  secure.values['animewitcher_account_session_v1'] = jsonEncode(
    session.toJson(),
  );
  secure.values['animewitcher_account_profile_v1'] = jsonEncode(
    profile.toJson(),
  );

  final service = AnimeWitcherAccountService(
    storage: backing,
    secureStorage: secure,
    firestore: firestore,
    diagnostics: diagnostics,
  );
  await service.restoreCachedSession();
  expect(service.isSignedIn, isTrue);
  return service;
}

MultimediaItem _manga() => MultimediaItem(
  title: 'Manga One',
  url: 'https://animewitcher.com/manga/m1',
  posterUrl: 'https://img.example/m1.webp',
  contentType: MultimediaContentType.manga,
  provider: AnimeWitcherAccountService.animeWitcherProvider,
  syncData: const <String, String>{'mangaId': 'm1'},
);

FirestoreDocument _remote({
  required String path,
  required Map<String, dynamic> fields,
}) => FirestoreDocument(id: path.split('/').last, path: path, fields: fields);

void main() {
  test('server-only manga removal stays hidden after restart and preserves favorites', () async {
    final storage = _Storage();
    final firestore = _Firestore();
    final manga = _manga();
    const list = 'users/profile-1/user_manga';
    const favorites = 'users/profile-1/fav_manga';
    firestore.collections[list] = [
      _remote(
        path: '$list/legacy',
        fields: {
          'doc_ref': 'manga_list/m1',
          'type': 'on_Hold',
          'name': manga.title,
          'image': manga.posterUrl,
        },
      ),
    ];
    firestore.collections[favorites] = [
      _remote(path: '$favorites/m1', fields: {'manga_doc_id': 'manga_list/m1'}),
    ];
    final account = await _signedInService(firestore, storage: storage);
    expect(await account.fetchMangaLibraryMembership(manga), (
      category: LibraryCategory.continueLater,
      favorite: true,
    ));

    firestore.failedCollection = list;
    await expectLater(
      account.removeMangaLibraryItem(manga.url, keepFavorite: true),
      throwsStateError,
    );
    final reopened = await _signedInService(firestore, storage: storage);
    expect(await reopened.fetchMangaLibraryMembership(manga), (
      category: null,
      favorite: true,
    ));
    final shelf = await reopened.fetchLibraryPage(
      category: LibraryCategory.continueLater,
      manga: true,
    );
    expect(shelf.items, isEmpty);
    expect(shelf.total, 0);

    firestore.failedCollection = null;
    await reopened.syncAll(includeLibrary: false);
    expect(firestore.collections[list], isEmpty);
    expect(firestore.collections[favorites], hasLength(1));
  });

  test('pending manga unfavorite keeps the reading list and retries the favorite removal', () async {
    final storage = _Storage();
    final firestore = _Firestore();
    final manga = _manga();
    const list = 'users/profile-1/user_manga';
    const favorites = 'users/profile-1/fav_manga';
    firestore.collections[list] = [
      _remote(path: '$list/m1', fields: {'type': 'watching'}),
    ];
    firestore.collections[favorites] = [
      _remote(path: '$favorites/m1', fields: {}),
    ];
    final account = await _signedInService(firestore, storage: storage);
    const desired = (category: LibraryCategory.watching, favorite: false);
    firestore.failedCollection = favorites;
    await expectLater(
      account.saveLibraryField(manga, desired, changeFavorite: true),
      throwsStateError,
    );

    final reopened = await _signedInService(firestore, storage: storage);
    expect(await reopened.fetchMangaLibraryMembership(manga), desired);
    firestore.failedCollection = null;
    await reopened.syncAll(includeLibrary: false);
    expect(firestore.collections[favorites], isEmpty);
    expect(firestore.collections[list], hasLength(1));
  });

  test('details edits write only the selected library field', () async {
    final firestore = _Firestore();
    final service = await _signedInService(firestore);
    final show = MultimediaItem(
      title: 'Show One',
      url: 'https://animewitcher.com/watch/show-1',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
    );
    const membership = (
      category: LibraryCategory.continueLater,
      favorite: true,
    );
    await service.saveLibraryField(show, membership, changeFavorite: true);
    expect(firestore.writes.single.path, 'users/profile-1/fav_anime/show-1');
    expect(firestore.deletes, isEmpty);

    firestore.writes.clear();
    await service.saveLibraryField(show, membership, changeFavorite: false);
    expect(firestore.writes.single.path, 'users/profile-1/user_anime/show-1');
    expect(firestore.deletes, isEmpty);
  });

  test(
    'pending native list removal hides legacy rows and later deletes them',
    () async {
      final firestore = _Firestore();
      final storage = _Storage();
      final service = await _signedInService(firestore, storage: storage);
      const listPath = 'users/profile-1/user_anime';
      const favoritesPath = 'users/profile-1/fav_anime';
      const url = 'https://animewitcher.com/watch/show-1';
      const shelf = LibraryCategory.continueLater;
      final fields = {
        'doc_ref': 'anime_list/show-1',
        'name': 'Show One',
        'image': 'https://cdn.example/show-1.jpg',
        'type': 'on_Hold',
      };
      firestore.collections[listPath] = [
        _remote(path: '$listPath/legacy-row', fields: fields),
      ];
      firestore.collections[favoritesPath] = [
        _remote(path: '$favoritesPath/show-1', fields: fields),
      ];
      final before = await service.fetchLibraryPage(category: shelf);
      expect(before.items.single.url, url);

      firestore.failedCollection = listPath;
      await expectLater(
        service.removeLibraryItem(url, keepFavorite: true),
        throwsStateError,
      );
      final restored = await _signedInService(firestore, storage: storage);
      final pending = await restored.fetchLibraryPage(category: shelf);
      expect(pending.items, isEmpty);
      expect(pending.total, 0);
      expect(firestore.collections[listPath], hasLength(1));

      firestore.failedCollection = null;
      await restored.syncAll(includeLibrary: false);
      expect(firestore.deletes, contains('$listPath/legacy-row'));
      expect(firestore.collections[listPath], isEmpty);
      expect(firestore.collections[favoritesPath], hasLength(1));
    },
  );

  test(
    'saving after a failed list removal supersedes the pending delete',
    () async {
      final firestore = _Firestore();
      final service = await _signedInService(firestore);
      const listPath = 'users/profile-1/user_anime';
      final legacy = _remote(
        path: '$listPath/legacy-row',
        fields: {
          'doc_ref': 'anime_list/show-1',
          'name': 'Show One',
          'image': 'https://cdn.example/show-1.jpg',
          'type': 'on_Hold',
        },
      );
      firestore.collections[listPath] = [legacy];
      final page = await service.fetchLibraryPage(
        category: LibraryCategory.continueLater,
      );
      final show = page.items.single;
      firestore.failedCollection = listPath;
      await expectLater(
        service.removeLibraryItem(show.url, keepFavorite: true),
        throwsStateError,
      );

      firestore.failedCollection = null;
      await service.saveLibraryItem(show, LibraryCategory.planToWatch);
      final write = firestore.writes.single;
      firestore.collections[listPath]!.add(
        _remote(path: write.path, fields: write.fields),
      );
      await service.syncAll(includeLibrary: false);
      expect(firestore.collections[listPath]!.single.path, '$listPath/show-1');
    },
  );

  test('native library upgrades compact low-quality poster when HQ is on', () async {
    final firestore = _Firestore();
    final storage = _Storage()..highQualityPosters = true;
    const small = 'https://cdn.example/low-quality.jpg';
    const large = 'https://cdn.example/full-quality.jpg';
    firestore.collections['users/profile-1/user_anime'] = [
      _remote(
        path: 'users/profile-1/user_anime/show-1',
        fields: {
          'type': 'watching',
          'date': DateTime.utc(2026, 1, 1),
          'image': small,
          'animewitcher_item': {
            'title': 'Show One',
            'url': 'https://animewitcher.com/anime/show-1',
            'posterUrl': small,
            'type': 'anime',
          },
        },
      ),
    ];
    firestore.documents['anime_list/show-1'] = _remote(
      path: 'anime_list/show-1',
      fields: {
        'poster': {'large': large},
        'poster_uri': small,
      },
    );
    final service = await _signedInService(firestore, storage: storage);
    final result = await service.fetchLibraryPage(
      category: LibraryCategory.watching,
    );
    expect(result.items.single.posterUrl, large);
    expect(firestore.posterBatchRequests, [
      ['show-1'],
    ]);
    expect(
      firestore.detailRequests,
      isEmpty,
      reason:
          'Library poster quality must not trigger per-title full detail GETs',
    );
  });

  test('native library keeps compact poster with HQ disabled', () async {
    final firestore = _Firestore();
    final storage = _Storage()..highQualityPosters = false;
    const small = 'https://cdn.example/low-quality.jpg';
    firestore.collections['users/profile-1/user_anime'] = [
      _remote(
        path: 'users/profile-1/user_anime/show-1',
        fields: {
          'type': 'watching',
          'date': DateTime.utc(2026, 1, 1),
          'image': small,
          'animewitcher_item': {
            'title': 'Show One',
            'url': 'https://animewitcher.com/anime/show-1',
            'posterUrl': small,
            'type': 'anime',
          },
        },
      ),
    ];
    final service = await _signedInService(firestore, storage: storage);
    final result = await service.fetchLibraryPage(
      category: LibraryCategory.watching,
    );
    expect(result.items.single.posterUrl, small);
    expect(firestore.posterBatchRequests, isEmpty);
    expect(firestore.detailRequests, isEmpty);
  });

  test('native library does not query catalog when shelf already has a large poster', () async {
    final firestore = _Firestore();
    final storage = _Storage()..highQualityPosters = true;
    const small = 'https://cdn.example/low.jpg';
    const large = 'https://cdn.example/high.jpg';
    firestore.collections['users/profile-1/user_anime'] = [
      _remote(
        path: 'users/profile-1/user_anime/show-2',
        fields: {
          'type': 'watching',
          'date': DateTime.utc(2026, 1, 1),
          'image': small,
          'poster': {'large': large},
          'animewitcher_item': {
            'title': 'Show Two',
            'url': 'https://animewitcher.com/anime/show-2',
            'posterUrl': small,
            'type': 'anime',
          },
        },
      ),
    ];
    final service = await _signedInService(firestore, storage: storage);
    final page = await service.fetchLibraryPage(
      category: LibraryCategory.watching,
    );
    expect(page.items.single.posterUrl, large);
    expect(firestore.posterBatchRequests, isEmpty);
  });

  test('native library batches missing poster lookups and caches successful results', () async {
    final firestore = _Firestore();
    final storage = _Storage()..highQualityPosters = true;
    firestore.collections['users/profile-1/user_anime'] = [
      for (var i = 0; i < 3; i++)
        _remote(
          path: 'users/profile-1/user_anime/show-$i',
          fields: {
            'type': 'watching',
            'date': DateTime.utc(2026, 1, 1),
            'image': 'https://cdn.example/small-$i.jpg',
            'animewitcher_item': {
              'title': 'Show $i',
              'url': 'https://animewitcher.com/anime/show-$i',
              'posterUrl': 'https://cdn.example/small-$i.jpg',
              'type': 'anime',
            },
          },
        ),
    ];
    for (var i = 0; i < 3; i++) {
      firestore.documents['anime_list/show-$i'] = _remote(
        path: 'anime_list/show-$i',
        fields: {
          'poster': {'large': 'https://cdn.example/large-$i.jpg'},
        },
      );
    }
    final service = await _signedInService(firestore, storage: storage);
    for (var request = 0; request < 2; request++) {
      final page = await service.fetchLibraryPage(
        category: LibraryCategory.watching,
      );
      expect(page.items.map((item) => item.posterUrl), [
        for (var i = 0; i < 3; i++) 'https://cdn.example/large-$i.jpg',
      ]);
    }
    expect(firestore.posterBatchRequests, hasLength(1));
    expect(firestore.posterBatchRequests.single, [
      'show-0',
      'show-1',
      'show-2',
    ]);
    expect(firestore.detailRequests, isEmpty);
  });

  test(
    'unavailable high-quality poster service keeps library thumbnails visible',
    () async {
      final firestore = _Firestore()..failPosterBatch = true;
      final storage = _Storage()..highQualityPosters = true;
      firestore.collections['users/profile-1/user_anime'] = [
        _remote(
          path: 'users/profile-1/user_anime/show-3',
          fields: {
            'type': 'watching',
            'date': DateTime.utc(2026, 1, 1),
            'image': 'https://cdn.example/small.jpg',
            'animewitcher_item': {
              'title': 'Show Three',
              'url': 'https://animewitcher.com/anime/show-3',
              'posterUrl': 'https://cdn.example/small.jpg',
              'type': 'anime',
            },
          },
        ),
      ];
      final service = await _signedInService(firestore, storage: storage);
      final page = await service.fetchLibraryPage(
        category: LibraryCategory.watching,
      );
      expect(page.items.single.posterUrl, 'https://cdn.example/small.jpg');
      expect(firestore.detailRequests, isEmpty);
    },
  );

  test(
    'legacy library details are resolved in a single masked batchGet',
    () async {
      final firestore = _Firestore();
      firestore.collections['users/profile-1/user_anime'] = [
        for (var i = 0; i < 3; i++)
          _remote(
            path: 'users/profile-1/user_anime/a$i',
            fields: {'type': 'watching', 'date': DateTime.utc(2026, 1, 1)},
          ),
      ];
      for (var i = 0; i < 3; i++) {
        firestore.documents['anime_list/a$i'] = _remote(
          path: 'anime_list/a$i',
          fields: {
            'name': 'Anime $i',
            'poster': {'large': 'https://cdn.example/large-$i.jpg'},
          },
        );
      }
      final service = await _signedInService(firestore);
      final page = await service.fetchLibraryPage(
        category: LibraryCategory.watching,
      );
      expect(firestore.libraryBatchRequests, hasLength(1));
      expect(firestore.libraryBatchRequests.single.manga, isFalse);
      expect(firestore.libraryBatchRequests.single.ids, ['a0', 'a1', 'a2']);
      expect(firestore.detailRequests, isEmpty);
      expect(firestore.posterBatchRequests, isEmpty);
      expect(page.items.map((item) => item.title), [
        'Anime 0',
        'Anime 1',
        'Anime 2',
      ]);
      expect(page.items.map((item) => item.posterUrl), [
        'https://cdn.example/large-0.jpg',
        'https://cdn.example/large-1.jpg',
        'https://cdn.example/large-2.jpg',
      ]);
      expect(page.total, 3);
      expect(page.hasMore, isFalse);
      expect(firestore.pageRequests, hasLength(1));
    },
  );

  test(
    'legacy library details fall back to concurrent GETs when batchGet fails',
    () async {
      final firestore = _Firestore()
        ..failLibraryBatch = true
        ..blockDetails = Completer<void>();
      firestore.collections['users/profile-1/user_anime'] = [
        for (var i = 0; i < 3; i++)
          _remote(
            path: 'users/profile-1/user_anime/a$i',
            fields: {'type': 'watching', 'date': DateTime.utc(2026, 1, 1)},
          ),
      ];
      for (var i = 0; i < 3; i++) {
        firestore.documents['anime_list/a$i'] = _remote(
          path: 'anime_list/a$i',
          fields: {'name': 'Anime $i', 'poster_uri': ''},
        );
      }
      final service = await _signedInService(firestore);
      final loading = service.fetchLibraryPage(
        category: LibraryCategory.watching,
      );
      try {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          firestore.detailRequests,
          hasLength(3),
          reason: 'Fallback starts all missing-detail tasks together',
        );
      } finally {
        firestore.blockDetails!.complete();
      }
      final page = await loading;
      expect(page.items.map((item) => item.title), [
        'Anime 0',
        'Anime 1',
        'Anime 2',
      ]);
      expect(page.total, 3);
      expect(page.hasMore, isFalse);
      expect(firestore.pageRequests, hasLength(1));
    },
  );

  test(
    'display page returns 30 shelf items and total without reconciliation',
    () async {
      final firestore = _Firestore();
      final storage = _Storage();
      final local = _manga();
      await storage.addToLibrary(
        local,
        category: 'completed',
        favorite: true,
        updatedAt: 10,
        syncedAccountUid: 'uid-1',
        syncedAt: 10,
      );
      firestore.collections['users/profile-1/user_manga'] = List.generate(
        65,
        (i) => _remote(
          path: 'users/profile-1/user_manga/m$i',
          fields: {
            'type': 'watching',
            'date': DateTime.utc(2026, 1, 1),
            'animewitcher_item': {
              'title': 'Manga $i',
              'url': 'https://animewitcher.com/manga/m$i',
              'posterUrl': '',
              'type': 'manga',
            },
          },
        ),
      );
      final service = await _signedInService(firestore, storage: storage);
      final first = await service.fetchLibraryPage(
        category: LibraryCategory.watching,
        manga: true,
      );
      expect(first.items, hasLength(30));
      expect(first.total, 65);
      expect(first.hasMore, isTrue);
      final second = await service.fetchLibraryPage(
        category: LibraryCategory.watching,
        manga: true,
        cursor: first.nextCursor,
      );
      expect(second.items, hasLength(30));
      expect(second.items.first.title, 'Manga 30');
      final last = await service.fetchLibraryPage(
        category: LibraryCategory.watching,
        manga: true,
        cursor: second.nextCursor,
      );
      expect(last.items, hasLength(5));
      expect(last.hasMore, isFalse);
      expect(firestore.pageRequests, hasLength(3));
      expect(firestore.queries, isEmpty);
      expect(firestore.writes, isEmpty);
      expect(firestore.deletes, isEmpty);
      expect(storage.library.keys, [local.url]);
      expect(storage.categories[local.url], 'completed');
      expect(storage.favorites[local.url], isTrue);
      await expectLater(
        service.fetchLibraryPage(
          category: LibraryCategory.completed,
          manga: true,
          cursor: first.nextCursor,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'automatic sync uploads dirty library entries without snapshot reads',
    () async {
      final firestore = _Firestore();
      final storage = _Storage();
      await storage.addToLibrary(
        _manga(),
        category: 'watching',
        updatedAt: 20,
        syncedAccountUid: 'uid-1',
        syncedAt: 10,
      );
      final service = await _signedInService(firestore, storage: storage);
      await service.syncAll(includeLibrary: false);
      expect(firestore.queries, isEmpty);
      expect(
        firestore.writes.any((w) => w.path == 'users/profile-1/user_manga/m1'),
        isTrue,
      );
      expect(storage.library, hasLength(1));
    },
  );

  test(
    'syncAll records five successful stages with only safe fields',
    () async {
      final sink = InMemoryDownloadDiagnosticsV2();
      final service = await _signedInService(
        _Firestore(),
        diagnostics: AppDiagnostics(sink: sink),
      );

      await service.syncAll();

      expect(sink.transportEvents, hasLength(5));
      expect(
        sink.transportEvents.map((event) => event['status']),
        unorderedEquals([
          'animeLibrary',
          'mangaLibrary',
          'watchedEpisodes',
          'watchedManga',
          'continueWatching',
        ]),
      );
      for (final event in sink.transportEvents) {
        expect(event, {
          'event': 'native.sync.stage',
          'status': isA<String>(),
          'durationMs': isNonNegative,
          'result': true,
        });
      }
    },
  );

  test('syncAll identifies failed stage and preserves its error', () async {
    final sink = InMemoryDownloadDiagnosticsV2();
    final firestore = _Firestore()
      ..failedCollection = 'users/profile-1/chapters_watched';
    final service = await _signedInService(
      firestore,
      diagnostics: AppDiagnostics(sink: sink),
    );

    await expectLater(service.syncAll(), throwsA(same(firestore.stageError)));

    expect(sink.transportEvents, hasLength(5));
    final failed = sink.transportEvents.where(
      (event) => event['result'] == false,
    );
    expect(failed.single, {
      'event': 'native.sync.stage',
      'status': 'watchedManga',
      'durationMs': isNonNegative,
      'result': false,
    });
    expect(
      sink.transportEvents.where((event) => event['result'] == true),
      hasLength(4),
    );
    expect(sink.transportEvents.toString(), isNot(contains('private')));
    expect(sink.transportEvents.toString(), isNot(contains('uid-1')));
    expect(service.snapshot.lastSyncAt, isNull);
  });

  test(
    'opening Witcher anime library requests only native anime shelves',
    () async {
      final firestore = _Firestore();
      final service = await _signedInService(firestore);

      await service.refreshLibraryForDisplay();

      expect(firestore.queries, [
        'users/profile-1/fav_anime',
        'users/profile-1/user_anime',
      ]);
      expect(firestore.writes, isEmpty);
    },
  );

  test(
    'opening Witcher manga library does not synchronize unrelated account data',
    () async {
      final firestore = _Firestore();
      final service = await _signedInService(firestore);

      await service.refreshLibraryForDisplay(manga: true);

      expect(firestore.queries, [
        'users/profile-1/fav_manga',
        'users/profile-1/user_manga',
      ]);
      expect(firestore.writes, isEmpty);
    },
  );

  test(
    'repeated Witcher shelf requests coalesce onto one cloud read',
    () async {
      final firestore = _Firestore();
      final service = await _signedInService(firestore);
      await Future.wait([
        service.refreshLibraryForDisplay(),
        service.refreshLibraryForDisplay(),
      ]);
      expect(firestore.queries, [
        'users/profile-1/fav_anime',
        'users/profile-1/user_anime',
      ]);
    },
  );

  test(
    'Witcher library cache stays intact when the network is offline',
    () async {
      final firestore = _Firestore()..offline = true;
      final storage = _Storage();
      final cached = _manga();
      await storage.addToLibrary(
        cached,
        category: LibraryCategory.watching.storageKey,
      );
      final service = await _signedInService(firestore, storage: storage);
      await expectLater(
        service.refreshLibraryForDisplay(manga: true),
        throwsStateError,
      );
      expect(storage.library[cached.url], cached);
      expect(
        storage.categories[cached.url],
        LibraryCategory.watching.storageKey,
      );
    },
  );
  test(
    'manga list write uses user_manga and official reference fields',
    () async {
      final firestore = _Firestore();
      final service = await _signedInService(firestore);

      await service.saveMangaLibraryItem(
        _manga(),
        LibraryCategory.watching,
        favorite: false,
      );

      final listWrite = firestore.writes.singleWhere(
        (write) => write.path == 'users/profile-1/user_manga/m1',
      );
      expect(listWrite.fields['type'], 'watching');
      expect(listWrite.fields['views'], 0);
      expect(listWrite.fields.containsKey('manga_id'), isFalse);
      final reference = listWrite.fields['doc_ref'];
      expect(reference, isA<FirestoreReference>());
      expect((reference as FirestoreReference).path, 'manga_list/m1');
      expect(listWrite.serverTimestampFields, <String>{'date'});
      expect(
        firestore.writes.any((write) => write.path.contains('user_anime')),
        isFalse,
      );
    },
  );

  test(
    'manga favorite write uses fav_manga and manga_doc_id reference',
    () async {
      final firestore = _Firestore();
      final service = await _signedInService(firestore);

      await service.saveMangaLibraryItem(
        _manga(),
        LibraryCategory.planToWatch,
        favorite: true,
      );

      final favorite = firestore.writes.singleWhere(
        (write) => write.path == 'users/profile-1/fav_manga/m1',
      );
      expect(favorite.fields['views'], 0);
      expect(favorite.fields.containsKey('manga_id'), isFalse);
      final reference = favorite.fields['manga_doc_id'];
      expect(reference, isA<FirestoreReference>());
      expect((reference as FirestoreReference).path, 'manga_list/m1');
      expect(favorite.serverTimestampFields, <String>{'date'});
      expect(
        firestore.writes.any((write) => write.path.contains('fav_anime')),
        isFalse,
      );
    },
  );

  test('removing manga deletes both official manga documents only', () async {
    final firestore = _Firestore();
    final service = await _signedInService(firestore);

    await service.removeMangaLibraryItem(_manga().url);

    expect(
      firestore.deletes,
      containsAll(<String>[
        'users/profile-1/user_manga/m1',
        'users/profile-1/fav_manga/m1',
      ]),
    );
    expect(
      firestore.deletes.any(
        (path) => path.contains('user_anime') || path.contains('fav_anime'),
      ),
      isFalse,
    );
  });

  test(
    'manga library round-trips from cloud across relaunch and remote delete',
    () async {
      final firestore = _Firestore();
      final storage = _Storage();
      final remoteDate = DateTime.utc(2026, 9, 20, 12);
      firestore.collections['users/profile-1/user_manga'] = <FirestoreDocument>[
        _remote(
          path: 'users/profile-1/user_manga/m1',
          fields: <String, dynamic>{
            'doc_ref': 'manga_list/m1',
            'type': 'watching',
            'views': 0,
            'date': remoteDate,
          },
        ),
      ];
      firestore.collections['users/profile-1/fav_manga'] = <FirestoreDocument>[
        _remote(
          path: 'users/profile-1/fav_manga/m1',
          fields: <String, dynamic>{
            'manga_doc_id': 'manga_list/m1',
            'views': 0,
            'date': remoteDate,
          },
        ),
      ];
      firestore.documents['manga_list/m1'] = _remote(
        path: 'manga_list/m1',
        fields: <String, dynamic>{
          'name': 'Manga One',
          'type': 'مانهوا',
          'poster_uri': 'https://img.example/m1.webp',
          'story': 'Story',
        },
      );

      var service = await _signedInService(firestore, storage: storage);
      await service.syncAll();

      var manga = storage.library.values.single;
      expect(manga.contentType, MultimediaContentType.manga);
      expect(manga.title, 'Manga One');
      expect(
        storage.categories[manga.url],
        LibraryCategory.watching.storageKey,
      );
      expect(storage.favorites[manga.url], isTrue);
      expect(storage.syncedUid[manga.url], 'uid-1');

      service = await _signedInService(firestore, storage: storage);
      await service.syncAll();
      expect(storage.library.values.single.title, 'Manga One');

      firestore.collections['users/profile-1/user_manga'] =
          const <FirestoreDocument>[];
      firestore.collections['users/profile-1/fav_manga'] =
          const <FirestoreDocument>[];

      service = await _signedInService(firestore, storage: storage);
      await service.syncAll();
      expect(storage.library, isEmpty);
    },
  );
  test(
    'manga read selection uses APK chapters_watched array contract',
    () async {
      final firestore = _Firestore();
      final service = await _signedInService(firestore);

      await service.setMangaChaptersWatched(
        mangaId: 'm1',
        chapterIds: const <String>['5', '6'],
        watched: true,
      );

      final transform = firestore.arrayTransforms.single;
      expect(transform.path, 'users/profile-1/chapters_watched/m1');
      expect(transform.field, 'chapters_watched');
      expect(transform.values, <String>['5', '6']);
      expect(transform.append, isTrue);
      expect(transform.baseFields['user_id'], 'profile-1');
      expect(transform.baseFields['last_chapter_watched_id'], '6');
      expect(service.isMangaChapterWatchedCached('m1', '5'), isTrue);
      expect(service.isMangaChapterWatchedCached('m1', '6'), isTrue);
    },
  );

  test(
    'manga unread selection removes chapters without extra field writes',
    () async {
      final firestore = _Firestore();
      final service = await _signedInService(firestore);

      await service.setMangaChaptersWatched(
        mangaId: 'm1',
        chapterIds: const <String>['5', '6'],
        watched: false,
      );

      final transform = firestore.arrayTransforms.single;
      expect(transform.path, 'users/profile-1/chapters_watched/m1');
      expect(transform.field, 'chapters_watched');
      expect(transform.values, <String>['5', '6']);
      expect(transform.append, isFalse);
      expect(transform.baseFields, isEmpty);
    },
  );

  test('syncAll loads APK chapters_watched state for manga', () async {
    final firestore = _Firestore();
    firestore.collections['users/profile-1/chapters_watched'] =
        <FirestoreDocument>[
          _remote(
            path: 'users/profile-1/chapters_watched/m1',
            fields: <String, dynamic>{
              'chapters_watched': <String>['12', '13'],
              'last_chapter_watched_id': '13',
              'user_id': 'profile-1',
            },
          ),
        ];
    final service = await _signedInService(firestore);

    await service.syncAll();

    expect(service.isMangaChapterWatchedCached('m1', '12'), isTrue);
    expect(service.isMangaChapterWatchedCached('m1', '13'), isTrue);
    expect(service.isMangaChapterWatchedCached('m1', '14'), isFalse);
  });

  test(
    'manga read cache updates optimistically while cloud is offline',
    () async {
      final firestore = _Firestore()..failArrayTransforms = true;
      final service = await _signedInService(firestore);

      await expectLater(
        service.setMangaChaptersWatched(
          mangaId: 'm1',
          chapterIds: const <String>['7'],
          watched: true,
        ),
        throwsStateError,
      );

      expect(service.isMangaChapterWatchedCached('m1', '7'), isTrue);
    },
  );

  test('fetchLibraryPage resolves official v1.4.9 embedded anime and manga fields without detail GETs and caches counts', () async {
    final firestore = _Firestore();
    final storage = _Storage();
    final remoteDate = DateTime.utc(2026, 10, 1, 12);
    firestore.collections['users/profile-1/user_anime'] = <FirestoreDocument>[
      _remote(
        path: 'users/profile-1/user_anime/a1',
        fields: <String, dynamic>{
          'doc_ref': 'anime_list/a1',
          'name': 'Bleach TYBW',
          'image': 'https://img.example/a1.webp',
          'anime_type': 'TV',
          'year': 2022,
          'type': 'completed',
          'views': 0,
          'date': remoteDate,
        },
      ),
    ];
    firestore.collections['users/profile-1/user_manga'] = <FirestoreDocument>[
      _remote(
        path: 'users/profile-1/user_manga/m1',
        fields: <String, dynamic>{
          'doc_ref': 'manga_list/m1',
          'name': 'Solo Leveling',
          'image': 'https://img.example/m1.webp',
          'manga_type': 'مانهوا',
          'type': 'watching',
          'views': 0,
          'date': remoteDate,
        },
      ),
    ];

    final service = await _signedInService(firestore, storage: storage);
    firestore.detailRequests.clear();

    final animePage = await service.fetchLibraryPage(
      category: LibraryCategory.completed,
      manga: false,
    );
    final mangaPage = await service.fetchLibraryPage(
      category: LibraryCategory.watching,
      manga: true,
    );

    expect(firestore.detailRequests, isEmpty);
    expect(animePage.items.single.title, 'Bleach TYBW');
    expect(animePage.items.single.posterUrl, 'https://img.example/a1.webp');
    expect(animePage.items.single.year, 2022);
    expect(mangaPage.items.single.title, 'Solo Leveling');
    expect(mangaPage.items.single.posterUrl, 'https://img.example/m1.webp');
    expect(
      storage.getCachedLibraryCounts(
        providerKey: 'native',
        accountKey: 'uid-1',
        mediaKindKey: 'anime',
      )['completed'],
      1,
    );
    expect(
      storage.getCachedLibraryCounts(
        providerKey: 'native',
        accountKey: 'uid-1',
        mediaKindKey: 'manga',
      )['watching'],
      1,
    );
  });

  test(
    'fetchLibraryPage and fetchLibraryCounts wait for in-flight library writes',
    () async {
      final firestore = _Firestore();
      final storage = _Storage();
      final service = await _signedInService(firestore, storage: storage);
      final show = MultimediaItem(
        title: 'Dekisokonai',
        url: 'https://animewitcher.com/watch/show-99',
        posterUrl: 'https://img.example/show-99.webp',
        contentType: MultimediaContentType.anime,
      );
      firestore.collections['users/profile-1/user_anime'] = <FirestoreDocument>[
        _remote(
          path: 'users/profile-1/user_anime/show-99',
          fields: <String, dynamic>{
            'doc_ref': 'anime_list/show-99',
            'name': 'Dekisokonai',
            'image': 'https://img.example/show-99.webp',
            'anime_type': 'TV',
            'type': 'pin',
            'views': 0,
            'date': DateTime.utc(2026, 10, 1, 12),
          },
        ),
      ];

      firestore.blockWrites = Completer<void>();
      final writeFuture = service.saveLibraryItem(
        show,
        LibraryCategory.notInterested,
      );
      await Future<void>.delayed(Duration.zero);

      final pageFuture = service.fetchLibraryPage(
        category: LibraryCategory.notInterested,
      );
      final countsFuture = service.fetchLibraryCounts();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Before the write completes, reads must not query Firestore yet.
      expect(firestore.pageRequests, isEmpty);
      expect(firestore.countRequests, 0);

      // Update mock collection to reflect the write as it lands.
      firestore.collections['users/profile-1/user_anime'] = <FirestoreDocument>[
        _remote(
          path: 'users/profile-1/user_anime/show-99',
          fields: <String, dynamic>{
            'doc_ref': 'anime_list/show-99',
            'name': 'Dekisokonai',
            'image': 'https://img.example/show-99.webp',
            'anime_type': 'TV',
            'type': 'no_watching',
            'views': 0,
            'date': DateTime.utc(2026, 10, 2, 12),
          },
        ),
      ];
      firestore.blockWrites!.complete();

      await writeFuture;
      final page = await pageFuture;
      final counts = await countsFuture;

      expect(page.total, 1);
      expect(page.items.single.title, 'Dekisokonai');
      expect(counts[LibraryCategory.planToWatch], 0);
      expect(counts[LibraryCategory.notInterested], 1);
    },
  );
}
