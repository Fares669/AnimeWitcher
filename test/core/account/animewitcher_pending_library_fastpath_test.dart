import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firebase_auth_rest_client.dart';
import 'package:animewitcher/core/account/firebase_functions_rest_client.dart';
import 'package:animewitcher/core/account/firebase_storage_rest_client.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/app_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _uid = 'fixture-owner';
const _profileId = 'fixture-profile';
const _token = 'fixture-session';
const _root = 'users/$_profileId';
const _journal = 'animewitcher_account_pending_library_deletes_v1';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Storage extends StorageService {
  _Storage({required super.downloadPersistenceWorker});

  int projectedCards = 0;

  @override
  List<MultimediaItem> getLibraryItems({String? category}) {
    final items = super.getLibraryItems(category: category);
    projectedCards += items.length;
    return items;
  }
}

class _Reads {
  int urls = 0;
}

class _Row extends MapBase<String, dynamic> {
  _Row(this._row, this._reads);
  final Map<String, dynamic> _row;
  final _Reads _reads;

  @override
  dynamic operator [](Object? key) {
    if (key == 'url') _reads.urls++;
    return _row[key];
  }

  @override
  void operator []=(String key, dynamic value) => _row[key] = value;

  @override
  Iterable<String> get keys => _row.keys;

  @override
  void clear() => _row.clear();

  @override
  dynamic remove(Object? key) => _row.remove(key);
}

class _Secure extends SecureTokenStorage {
  _Secure(super.storage);
  final _values = <String, String>{
    'animewitcher_account_session_v1': jsonEncode(
      AnimeWitcherSession(
        uid: _uid,
        idToken: _token,
        refreshToken: 'fixture-refresh',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        signInMethod: AnimeWitcherSignInMethod.email,
      ).toJson(),
    ),
    'animewitcher_account_profile_v1': jsonEncode(
      const AnimeWitcherProfile(
        uid: _uid,
        documentId: _profileId,
        signInMethod: AnimeWitcherSignInMethod.email,
      ).toJson(),
    ),
  };

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

class _Firestore extends FirestoreRestClient {
  _Firestore(Dio dio) : super(dio: dio);
  final reads = <String>[];
  final writes = <(String, String, String)>[];
  final deletes = <String>[];
  final order = <String>[];
  final writeStarted = Completer<void>();
  Completer<void>? writeGate;
  String? delayedEarlyWrite;

  @override
  Future<List<FirestoreDocument>> listDocuments(
    String collectionPath,
    String idToken, {
    int pageSize = 100,
  }) async {
    expect(idToken, _token);
    reads.add(collectionPath);
    return const [];
  }

  @override
  Future<void> setDocumentWithServerTimestamps(
    String path,
    Map<String, dynamic> fields,
    String idToken, {
    required Set<String> serverTimestampFields,
    bool merge = true,
  }) async {
    expect(idToken, _token);
    if (path == delayedEarlyWrite) {
      writeStarted.complete();
      await writeGate!.future;
    }
    writes.add((path, fields['name'] as String, fields['type'] as String));
    order.add(path);
  }

  @override
  Future<void> deleteDocument(String path, String idToken) async {
    expect(idToken, _token);
    deletes.add(path);
    order.add(path);
  }
}

Map<String, dynamic> _row(
  String id, {
  bool manga = false,
  String? url,
  String? owner = _uid,
  int updated = 100,
  Object synced = 100,
  String title = 'Fixture card',
  String type = 'watching',
}) => {
  'title': title,
  'url': url ?? 'https://animewitcher.com/${manga ? 'manga' : 'watch'}/$id',
  'type': manga ? 'manga' : 'anime',
  'posterUrl': 'https://images.invalid/$id.png',
  'libraryCategory': type,
  'isFavorite': false,
  'updatedAt': updated,
  'animeWitcherSyncedUid': owner,
  'animeWitcherSyncedAt': synced,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage storage;
  late Box<dynamic> library;
  late _Firestore firestore;
  late AnimeWitcherAccountService account;

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp(
      'aw-pending-library-',
    );
    final previousPaths = PathProviderPlatform.instance;
    final worker = DownloadPersistenceWorker.forDirectory(directory.path);
    PathProviderPlatform.instance = _Paths(directory.path);
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            handler.reject(
              DioException(
                requestOptions: request,
                error: 'Fixture is offline',
              ),
            );
          },
        ),
      );
    addTearDown(() async {
      dio.close(force: true);
      await Hive.close();
      await worker.close();
      PathProviderPlatform.instance = previousPaths;
      await directory.delete(recursive: true);
    });
    storage = _Storage(downloadPersistenceWorker: worker);
    await storage.init();
    library = Hive.box<dynamic>(StorageService.kLibraryBox);
    firestore = _Firestore(dio);
    account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: _Secure(storage),
      firestore: firestore,
      auth: FirebaseAuthRestClient(dio: dio),
      functions: FirebaseFunctionsRestClient(dio: dio),
      cloudStorage: FirebaseStorageRestClient(dio: dio),
      diagnostics: AppDiagnostics(sink: const NoopDownloadDiagnosticsV2()),
    );
    expect((await account.restoreCachedSession()).isSignedIn, isTrue);
  });

  test('clean upload-only sync skips projecting the saved library', () async {
    const size = 1200;
    final counts = _Reads();
    final rows = {
      for (var index = 0; index < size; index++)
        index: _Row(
          _row(
            'card-$index',
            manga: index.isOdd,
            owner: index % 11 == 0 ? 'another-owner' : _uid,
            updated: index % 11 == 0 ? 300 : index % 19,
            title: 'Card $index',
          ),
          counts,
        ),
    };
    await library.putAll(rows);
    // Count live Hive row access, not writes or isolated synthetic work.
    expect(identical(library.get(0), rows[0]), isTrue);
    counts.urls = 0;

    for (var run = 0; run < 2; run++) {
      await account.syncAll(includeLibrary: false);
    }
    expect(firestore.writes, isEmpty);
    expect(firestore.deletes, isEmpty);
    expect(
      firestore.reads,
      unorderedEquals([
        for (var run = 0; run < 2; run++) ...[
          '$_root/episodes_watched',
          '$_root/chapters_watched',
          '$_root/continue_watching',
        ],
      ]),
    );
    expect(library.length, size);
    expect(storage.projectedCards, 0);
    expect(counts.urls, lessThanOrEqualTo(size * 4));
  });

  test('deletes run first; dirty, guest, duplicate and foreign rows retain authority', () async {
    await library.putAll({
      0: _row(
        'duplicate',
        url: ' HTTP://WWW.ANIMEWITCHER.COM/watch/duplicate/episode?x=y ',
      ),
      1: _row(
        'duplicate',
        manga: true,
        url: 'https://animewitcher.com/watch/duplicate',
        owner: null,
        updated: 999,
      ),
      2: _row('old', owner: null, title: 'guest'),
      3: _row('recent', title: 'dirty anime', updated: 300),
      4: _row('reading', manga: true, title: 'dirty manga', updated: 250),
      5: _row('foreign', owner: 'another-owner', updated: 400),
      6: _row('legacy-clean', synced: '100'),
      7: _row('legacy-dirty', synced: '99', title: 'legacy dirty'),
    });
    await storage.setString(
      _journal,
      jsonEncode({
        'deleted': {
          'anime_id': 'deleted',
          'owner_uid': _uid,
          'revision': 'original',
        },
      }),
    );

    await account.syncAll(includeLibrary: false);

    expect(
      firestore.writes,
      unorderedEquals([
        ('$_root/user_anime/recent', 'dirty anime', 'watching'),
        ('$_root/user_anime/old', 'guest', 'watching'),
        ('$_root/user_anime/legacy-dirty', 'legacy dirty', 'watching'),
        ('$_root/user_manga/reading', 'dirty manga', 'watching'),
      ]),
    );
    final deleted = firestore.order.indexOf('$_root/user_anime/deleted');
    final uploaded = firestore.order.indexOf('$_root/user_anime/recent');
    expect(deleted, greaterThanOrEqualTo(0));
    expect(uploaded, greaterThan(deleted));
    expect(
      storage.getLibraryItemSyncedAccountUid(
        'https://animewitcher.com/watch/old',
      ),
      _uid,
    );
    expect(
      storage.getLibraryItemSyncedAccountUid(
        'https://animewitcher.com/watch/foreign',
      ),
      'another-owner',
    );
    expect(jsonDecode(storage.getString(_journal) ?? '{}'), isEmpty);
  });

  test(
    'opposite-kind duplicate never inherits the first row dirty state',
    () async {
      const canonical = 'https://animewitcher.com/watch/shared';
      await library.putAll({
        0: _row(
          'shared',
          url: ' http://www.animewitcher.com/watch/shared/early ',
          title: 'First dirty anime',
          updated: 200,
        ),
        1: _row(
          'shared',
          url: canonical,
          title: 'Later clean manga',
          manga: true,
        ),
      });
      final item = storage.getLibraryItems().single;
      expect(item.url, canonical);
      expect(item.contentType, MultimediaContentType.anime);
      storage.projectedCards = 0;

      await account.syncAll(includeLibrary: false);

      expect(storage.projectedCards, 2);
      expect(firestore.writes, [
        ('$_root/user_anime/shared', 'First dirty anime', 'watching'),
      ]);
    },
  );

  test('ambiguous legacy rows keep the original projection path', () async {
    await library.put(0, {..._row('damaged'), 'posterUrl': 7});
    await expectLater(
      account.syncAll(includeLibrary: false),
      throwsA(isA<TypeError>()),
    );
    expect(firestore.writes, isEmpty);
  });

  test('invalid encoded legacy URLs keep the original failure', () async {
    await library.put(0, _row('%FF'));
    await expectLater(
      account.syncAll(includeLibrary: false),
      throwsFormatException,
    );
    expect(firestore.writes, isEmpty);
  });

  test(
    'fallback observes a later row edited while the first upload waits',
    () async {
      await library.putAll({
        0: _row('first', updated: 300, title: 'First'),
        1: _row('second', updated: 80, title: 'Original second'),
      });
      firestore.delayedEarlyWrite = '$_root/user_anime/first';
      final gate = firestore.writeGate = Completer<void>();
      final operation = account.syncAll(includeLibrary: false);
      try {
        await firestore.writeStarted.future.timeout(const Duration(seconds: 3));
        await library.put(
          1,
          _row(
            'second',
            updated: 400,
            type: 'completed',
            title: 'Locally edited second',
          ),
        );
      } finally {
        gate.complete();
      }

      await operation;
      // The original sorted snapshot supplies the card title; membership and
      // dirtiness are read from the currently persisted row after each wait.
      expect(firestore.writes, [
        ('$_root/user_anime/first', 'First', 'watching'),
        ('$_root/user_anime/second', 'Original second', 'completed'),
      ]);
    },
  );
}
