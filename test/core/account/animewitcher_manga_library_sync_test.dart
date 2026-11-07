import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/app_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

final class _Storage extends MemoryStorageService {
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

  @override
  Future<void> setDocumentWithServerTimestamps(
    String path,
    Map<String, dynamic> fields,
    String idToken, {
    required Set<String> serverTimestampFields,
    bool merge = true,
  }) async {
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
  }) async => (collections[collectionPath] ?? [])
      .where((d) => type == null || d.fields['type'] == type)
      .length;

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
  Future<FirestoreDocument?> getDocument(String path, String idToken) async =>
      documents[path];
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

  test('syncAll ignores legacy Rift manga records in native storage', () async {
    final firestore = _Firestore();
    final storage = _Storage();
    final rift = _manga().copyWith(
      provider: animeRiftProviderId,
      syncData: const <String, String>{'mangaId': 'rift-m1'},
      url: 'https://animewitcher.com/manga/rift-m1',
    );
    storage.library[rift.url] = rift;
    storage.categories[rift.url] = LibraryCategory.planToWatch.storageKey;
    storage.updatedAt[rift.url] = 100;
    storage.syncedAt[rift.url] = 100;
    storage.syncedUid[rift.url] = 'uid-1';
    final service = await _signedInService(firestore, storage: storage);

    await service.syncAll();

    expect(storage.library[rift.url]?.provider, animeRiftProviderId);
    expect(
      firestore.writes.any((write) => write.path.contains('rift-m1')),
      isFalse,
    );
    expect(firestore.deletes.any((path) => path.contains('rift-m1')), isFalse);
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
}
