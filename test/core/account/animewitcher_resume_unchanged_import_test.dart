import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firebase_auth_rest_client.dart';
import 'package:animewitcher/core/account/firebase_functions_rest_client.dart';
import 'package:animewitcher/core/account/firebase_storage_rest_client.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _uid = 'local-resume-owner';
const _profileId = 'local-resume-profile';
const _session = 'resume-offline-fixture';
const _root = 'users/$_profileId';
final _date = DateTime.utc(2025, 1, 6);

String _showId(int index) => 'resume-$index';
String _url(int index) => 'https://animewitcher.com/watch/${_showId(index)}';
String _episodeKey(int index) => 'EP_${_showId(index)}|local-ep';
String _stopPath(int index) =>
    '$_root/episodes_watched/${_showId(index)}/stop_times/local-ep';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _ResumeStorage extends StorageService {
  _ResumeStorage({required super.downloadPersistenceWorker});

  List<Map<String, dynamic>>? _observed;
  int newSnapshots = 0;
  int projectedRows = 0;

  @override
  List<Map<String, dynamic>> getContinueWatching() {
    final next = super.getContinueWatching();
    if (!identical(next, _observed)) {
      newSnapshots++;
      projectedRows += next.length;
      _observed = next;
    }
    return next;
  }
}

class _Secure extends SecureTokenStorage {
  _Secure(super.storage);

  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async => switch (key) {
    'animewitcher_account_session_v1' => jsonEncode(
      AnimeWitcherSession(
        uid: _uid,
        idToken: _session,
        refreshToken: 'unused-fixture',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        signInMethod: AnimeWitcherSignInMethod.email,
      ).toJson(),
    ),
    'animewitcher_account_profile_v1' => jsonEncode(
      const AnimeWitcherProfile(
        documentId: _profileId,
        uid: _uid,
        signInMethod: AnimeWitcherSignInMethod.email,
      ).toJson(),
    ),
    _ => null,
  };
}

Dio _offline() => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.reject(
        DioException(
          requestOptions: request,
          error: StateError('Unexpected transport for offline sync fixture'),
        ),
      ),
    ),
  );

class _Cloud extends FirestoreRestClient {
  _Cloud() : super(dio: _offline());

  final docs = <FirestoreDocument>[];
  final stop = <String, int>{};
  final reads = <String>[];
  Future<void> Function()? beforeResumeList;

  @override
  Future<List<FirestoreDocument>> listDocuments(
    String path,
    String idToken, {
    int pageSize = 100,
  }) async {
    expect(idToken, _session);
    reads.add(path);
    if (path == '$_root/continue_watching') {
      await beforeResumeList?.call();
      return List.of(docs);
    }
    if (path == '$_root/episodes_watched' ||
        path == '$_root/chapters_watched') {
      return [];
    }
    throw StateError('Unexpected mocked collection: $path');
  }

  @override
  Future<FirestoreDocument?> getDocument(String path, String idToken) async {
    expect(idToken, _session);
    reads.add(path);
    final position = stop[path];
    if (position == null) throw StateError('Unexpected mocked document: $path');
    return FirestoreDocument(
      id: 'local-ep',
      path: path,
      fields: {'stop_time': position},
    );
  }
}

class _Fixture {
  _Fixture(this.storage, this.box, this.cloud, this.service);

  final _ResumeStorage storage;
  final Box<dynamic> box;
  final _Cloud cloud;
  final AnimeWitcherAccountService service;
}

Future<_Fixture> _fixture(int rows) async {
  final temp = await Directory.systemTemp.createTemp('aw-resume-sync-');
  final previousPaths = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _Paths(temp.path);
  final worker = DownloadPersistenceWorker.forDirectory(
    temp.path,
    documentsDirectory: temp.path,
  );
  addTearDown(() async {
    await worker.close();
    await Hive.close();
    PathProviderPlatform.instance = previousPaths;
    await temp.delete(recursive: true);
  });
  final storage = _ResumeStorage(downloadPersistenceWorker: worker);
  await storage.init();
  final box = Hive.box<dynamic>(StorageService.kContinueWatchingBox);
  final cloud = _Cloud();
  for (var i = 0; i < rows; i++) {
    final item = MultimediaItem(
      title: 'Offline resume $i',
      url: _url(i),
      posterUrl: '',
      contentType: MultimediaContentType.anime,
    );
    cloud.docs.add(
      FirestoreDocument(
        id: _showId(i),
        path: '$_root/continue_watching/${_showId(i)}',
        fields: {
          'anime_id': _showId(i),
          'date_updated': _date,
          'animewitcher_item': item.toJson(),
          'episode_id': 'local-ep',
          'episode_name': 'الحلقة الأولى',
          'episode_number': 1,
          'progress': 20,
          'duration': 9000,
        },
      ),
    );
    cloud.stop[_stopPath(i)] = 1800 + i;
  }
  final service = AnimeWitcherAccountService(
    storage: storage,
    secureStorage: _Secure(storage),
    auth: FirebaseAuthRestClient(dio: _offline(), apiKey: 'offline'),
    firestore: cloud,
    cloudStorage: FirebaseStorageRestClient(
      dio: _offline(),
      storageBucket: 'offline',
    ),
    functions: FirebaseFunctionsRestClient(dio: _offline()),
  );
  await service.restoreCachedSession();
  expect(service.isSignedIn, isTrue);
  return _Fixture(storage, box, cloud, service);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'authoritative unchanged resume snapshots keep the exact local view',
    () async {
      const rows = 48;
      final f = await _fixture(rows);
      await f.service.syncAll(includeLibrary: false);
      final original = jsonEncode(f.storage.getContinueWatching());
      final originalRequests = List.of(f.cloud.reads);
      expect(f.box.length, rows * 2);
      for (var i = 0; i < rows; i++) {
        expect((f.box.get(_url(i)) as Map)['position'], 1800 + i);
        expect(f.box.get(_episodeKey(i)), f.box.get(_url(i)));
      }

      f.storage.newSnapshots = 0;
      f.storage.projectedRows = 0;
      f.cloud.reads.clear();
      final writes = <BoxEvent>[];
      final subscription = f.box.watch().listen(writes.add);
      addTearDown(subscription.cancel);
      await f.service.syncAll(includeLibrary: false);
      expect(jsonEncode(f.storage.getContinueWatching()), original);
      await Future<void>.delayed(Duration.zero);
      expect(f.cloud.reads, originalRequests);
      expect(writes, isEmpty);
      expect(f.storage.newSnapshots, 0);
      expect(f.storage.projectedRows, 0);

      // Repair missing and legacy rows, and retain the latest remote position.
      await f.box.delete(_episodeKey(0));
      f.cloud.stop[_stopPath(1)] = 2500;
      await f.box.put(_episodeKey(2), {
        ...(f.box.get(_episodeKey(2)) as Map),
        'legacy': true,
      });
      await f.box.put(_url(3), {
        ...(f.box.get(_url(3)) as Map),
        'position': 1803.0,
      });
      await Future<void>.delayed(Duration.zero);
      writes.clear();
      await f.service.syncAll(includeLibrary: false);
      await Future<void>.delayed(Duration.zero);
      expect(f.box.get(_episodeKey(0)), f.box.get(_url(0)));
      expect((f.box.get(_url(1)) as Map)['position'], 2500);
      expect(f.box.get(_episodeKey(1)), f.box.get(_url(1)));
      expect(f.box.get(_episodeKey(2)), f.box.get(_url(2)));
      expect((f.box.get(_url(3)) as Map)['position'], isA<int>());
      expect(writes, hasLength(8));

      // Server deletion remains authoritative, including its local episode row.
      f.cloud.docs.removeLast();
      await f.service.syncAll(includeLibrary: false);
      expect(f.box.get(_url(rows - 1)), isNull);
      expect(f.box.get(_episodeKey(rows - 1)), isNull);
    },
  );

  test(
    'identical import while a local storage write is pending still saves',
    () async {
      final f = await _fixture(0);
      final item = MultimediaItem(
        title: 'Live resume fixture',
        url: _url(0),
        posterUrl: '',
        contentType: MultimediaContentType.anime,
      );
      final writes = <BoxEvent>[];
      final subscription = f.box.watch().listen(writes.add);
      addTearDown(subscription.cancel);

      Future<void> save({bool fromCloud = true}) =>
          f.storage.saveContinueWatchingProgress(
            item,
            4200,
            8000,
            lastEpisodeUrl: '${_showId(0)}|local-ep',
            timestamp: 7000,
            syncedAccountUid: fromCloud ? _uid : null,
            syncedAt: fromCloud ? 7000 : null,
          );

      final first = save();
      final second = save();
      await Future.wait<void>([first, second]);
      await Future<void>.delayed(Duration.zero);
      expect(writes, hasLength(4));
      expect((f.box.get(_url(0)) as Map)['position'], 4200);
      expect(f.box.get(_episodeKey(0)), f.box.get(_url(0)));

      // Even a matching local save still follows the ordinary persistence path.
      writes.clear();
      await save(fromCloud: false);
      await Future<void>.delayed(Duration.zero);
      expect(writes, hasLength(2));
    },
  );

  test('an alternate legacy URL remains separate from the exact row', () async {
    final f = await _fixture(1);
    await f.service.syncAll(includeLibrary: false);
    final url = '${_url(0)}?legacy=1';
    final legacy = MultimediaItem(
      title: 'Legacy copy of the same show',
      url: url,
      posterUrl: '',
      contentType: MultimediaContentType.anime,
    );
    final timestamp = _date.millisecondsSinceEpoch;
    final legacyEpisode = '${_showId(0)}|legacy-ep';
    await f.storage.saveContinueWatchingProgress(
      legacy,
      5500,
      8000,
      lastEpisodeUrl: legacyEpisode,
      timestamp: timestamp,
      syncedAccountUid: _uid,
      syncedAt: timestamp,
    );
    expect(f.box.length, 4);
    final original = jsonEncode(f.storage.getContinueWatching());
    final writes = <BoxEvent>[];
    final subscription = f.box.watch().listen(writes.add);
    addTearDown(subscription.cancel);
    await f.service.syncAll(includeLibrary: false);
    await Future<void>.delayed(Duration.zero);
    expect(writes, isEmpty);
    expect(jsonEncode(f.storage.getContinueWatching()), original);
    expect(f.box.get('EP_$legacyEpisode'), f.box.get(url));
    expect((f.box.get(_url(0)) as Map)['position'], 1800);
    expect((f.box.get(url) as Map)['position'], 5500);
  });

  test('a resume list arriving after sign-out does not hydrate Hive', () async {
    final f = await _fixture(1);
    final listStarted = Completer<void>();
    final allowList = Completer<void>();
    f.cloud.beforeResumeList = () {
      listStarted.complete();
      return allowList.future;
    };
    final syncing = f.service.syncAll(includeLibrary: false);
    await listStarted.future;
    try {
      await f.service.signOut();
    } finally {
      allowList.complete();
    }
    await syncing;
    expect(f.service.isSignedIn, isFalse);
    expect(f.cloud.reads, isNot(contains(_stopPath(0))));
    expect(f.box.isEmpty, isTrue);
  });

  test(
    'failed resume read leaves existing rows intact for the next sync',
    () async {
      final f = await _fixture(1);
      await f.service.syncAll(includeLibrary: false);
      final original = jsonEncode(f.storage.getContinueWatching());
      f.cloud.stop.remove(_stopPath(0));
      await expectLater(
        f.service.syncAll(includeLibrary: false),
        throwsStateError,
      );
      expect(jsonEncode(f.storage.getContinueWatching()), original);
      f.cloud.stop[_stopPath(0)] = 2000;
      await f.service.syncAll(includeLibrary: false);
      expect((f.box.get(_url(0)) as Map)['position'], 2000);
      expect(f.box.get(_episodeKey(0)), f.box.get(_url(0)));
    },
  );
}
