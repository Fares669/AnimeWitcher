import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_sync_ids.dart';
import 'package:animewitcher/core/account/firebase_auth_rest_client.dart';
import 'package:animewitcher/core/account/firebase_functions_rest_client.dart';
import 'package:animewitcher/core/account/firebase_storage_rest_client.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/app_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

const _profile = AnimeWitcherProfile(
  documentId: 'fixture-profile',
  uid: 'fixture-user',
  signInMethod: AnimeWitcherSignInMethod.email,
  email: 'fixture@example.invalid',
  userName: 'Fixture',
  providerIds: ['password'],
);
const _sessionsKey = 'animewitcher_account_session_v1';
const _profileKey = 'animewitcher_account_profile_v1';
const _episodes = 'episodes_watched';
const _chapters = 'chapters_watched';
const _resume = 'continue_watching';

class _AccountStorage extends MemoryStorageService {
  @override
  List<MultimediaItem> getLibraryItems({String? category}) => const [];

  @override
  List<Map<String, dynamic>> getContinueWatching() => const [];

  @override
  Future<void> remove(String key) async {
    settings.remove(key);
  }
}

class _SecureStorage extends SecureTokenStorage {
  _SecureStorage(super.storage);

  final values = <String, String>{};

  void seed(String token) {
    values[_sessionsKey] = jsonEncode(
      AnimeWitcherSession(
        uid: _profile.uid,
        idToken: token,
        refreshToken: 'fixture-refresh',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        signInMethod: _profile.signInMethod,
        email: _profile.email,
        providerIds: _profile.providerIds,
      ).toJson(),
    );
    values[_profileKey] = jsonEncode(_profile.toJson());
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

Dio _offlineTransport() => Dio()
  ..interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.reject(
        DioException(
          requestOptions: request,
          error: StateError('Network is disabled for this test'),
        ),
      ),
    ),
  );

class _Auth extends FirebaseAuthRestClient {
  _Auth(Dio dio) : super(dio: dio);

  @override
  Future<Map<String, dynamic>> lookup(String idToken) async => {
    'emailVerified': true,
    'email': _profile.email,
    'providerUserInfo': [
      {'providerId': 'password'},
    ],
  };

  @override
  Future<void> signOut() async {}
}

class _Functions extends FirebaseFunctionsRestClient {
  _Functions(Dio dio) : super(dio: dio);

  @override
  Future<void> syncNewAuthEmailToFirestore(String idToken) async {}
}

class _Counts {
  int rebuiltSets = 0;
  int projectedIds = 0;
}

// Tracks the normalization pass at the fake transport's decoded-list boundary.
// Does not count Firestore decoding, transport work, or process allocation.
class _CountedIds extends ListBase<Object?> {
  _CountedIds(this.values, this.counts);

  final List<Object?> values;
  final _Counts counts;

  @override
  int get length => values.length;

  @override
  set length(int _) => throw UnsupportedError('read-only fixture');

  @override
  Object? operator [](int index) => values[index];

  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('read-only fixture');

  @override
  Iterable<T> map<T>(T Function(Object?) toElement) {
    counts.rebuiltSets++;
    counts.projectedIds += values.length;
    return values.map(toElement);
  }
}

class _SnapshotHold {
  final release = Completer<void>();
  final started = Completer<void>();
  int _watchedReads = 0;

  Future<void> onRead() async {
    if (++_watchedReads == 2) started.complete();
    await release.future;
  }
}

FirestoreDocument _doc(
  String field,
  String id,
  Object? values, {
  bool all = false,
}) => FirestoreDocument(
  id: id,
  path: 'users/${_profile.documentId}/$field/$id',
  fields: {field: values, if (all) 'all_eps_watched': true},
);

class _Firestore extends FirestoreRestClient {
  _Firestore(Dio dio) : super(dio: dio);

  final snapshots = <String, List<FirestoreDocument>>{
    _episodes: [],
    _chapters: [],
    _resume: [],
  };
  final reads = <String>[];
  final writes = <(String, List<dynamic>, bool)>[];
  _SnapshotHold? hold;

  @override
  Future<List<FirestoreDocument>> queryByStringField({
    required String collectionId,
    required String field,
    required String value,
    required String idToken,
    int limit = 20,
  }) async {
    expect((collectionId, field, value), ('users', 'uid', _profile.uid));
    return const [
      FirestoreDocument(
        id: 'fixture-profile',
        path: 'users/fixture-profile',
        fields: {'uid': 'fixture-user', 'user_name': 'Fixture'},
      ),
    ];
  }

  @override
  Future<List<FirestoreDocument>> listDocuments(
    String collectionPath,
    String idToken, {
    int pageSize = 100,
  }) async {
    final collection = collectionPath.split('/').last;
    if (collectionPath != 'users/${_profile.documentId}/$collection' ||
        !snapshots.containsKey(collection)) {
      throw StateError('Unexpected collection: $collectionPath');
    }
    reads.add(collection);
    final result = snapshots[collection]!;
    if (collection != _resume) await hold?.onRead();
    return result;
  }

  @override
  Future<FirestoreDocument?> getDocument(String path, String idToken) async {
    for (final docs in snapshots.values) {
      for (final doc in docs) {
        if (doc.path == path) return doc;
      }
    }
    return null;
  }

  @override
  Future<void> transformArrayFieldValues(
    String path, {
    required String idToken,
    required String field,
    required Iterable<dynamic> values,
    required bool append,
    Map<String, dynamic> baseFields = const {},
  }) async {
    expect(idToken, 'fixture-token');
    expect(path, startsWith('users/${_profile.documentId}/$field/'));
    writes.add((field, values.toList(), append));
  }
}

class _Fixture {
  _Fixture() {
    secure = _SecureStorage(storage)..seed('fixture-token');
    final offline = _offlineTransport();
    firestore = _Firestore(offline);
    service = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: secure,
      auth: _Auth(offline),
      firestore: firestore,
      cloudStorage: FirebaseStorageRestClient(dio: offline),
      functions: _Functions(offline),
      diagnostics: AppDiagnostics(sink: const NoopDownloadDiagnosticsV2()),
    );
  }

  final storage = _AccountStorage();
  late final _Firestore firestore;
  late final _SecureStorage secure;
  late final AnimeWitcherAccountService service;

  Future<void> startup() async {
    expect((await service.restoreCachedSession()).isSignedIn, isTrue);
    expect(firestore.reads, isEmpty);
    expect((await service.refreshRestoredSession()).isSignedIn, isTrue);
    expect(firestore.reads, unorderedEquals([_episodes, _chapters, _resume]));
  }

  bool episodeCached(String anime, String episode) =>
      service.isEpisodeWatchedCached(
        AnimeWitcherSyncIds.mainUrl(anime),
        AnimeWitcherSyncIds.episodeUrl(anime, episode),
      );

  Future<Set<String>> episodes(String anime) =>
      service.watchedEpisodeIds(AnimeWitcherSyncIds.mainUrl(anime));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'startup loads every watched ID; unchanged foreground refreshes reuse sets',
    () async {
      const anime = 320;
      const manga = 240;
      const ids = 192;
      const repeats = 5;
      final fixture = _Fixture();
      final counts = _Counts();
      final values = List.generate(ids, (i) => 'item-$i');
      fixture.firestore.snapshots[_episodes] = [
        for (var i = 0; i < anime; i++)
          _doc(_episodes, 'anime-$i', _CountedIds(values, counts)),
      ];
      fixture.firestore.snapshots[_chapters] = [
        for (var i = 0; i < manga; i++)
          _doc(_chapters, 'manga-$i', _CountedIds(values, counts)),
      ];

      await fixture.startup();
      expect(counts.rebuiltSets, anime + manga);
      expect(counts.projectedIds, (anime + manga) * ids);
      counts.rebuiltSets = counts.projectedIds = 0;

      for (var i = 0; i < repeats; i++) {
        await fixture.service.syncAll(includeLibrary: false);
      }
      expect(counts.rebuiltSets, 0);
      expect(counts.projectedIds, 0);
      expect(fixture.firestore.reads, hasLength((repeats + 1) * 3));
      for (final category in [_episodes, _chapters, _resume]) {
        expect(
          fixture.firestore.reads.where((read) => read == category),
          hasLength(repeats + 1),
        );
      }
      expect(await fixture.episodes('anime-319'), orderedEquals(values));
      expect(
        await fixture.service.watchedMangaChapterIds('manga-239'),
        orderedEquals(values),
      );
    },
  );

  test(
    'watched snapshots remain authoritative for ordering, flags, and deletes',
    () async {
      final fixture = _Fixture();
      final firestore = fixture.firestore;
      firestore.snapshots[_episodes] = [
        _doc(_episodes, 'changed', ['a', 7, 'b'], all: true),
        _doc(_episodes, 'removed', ['was-watched']),
        _doc(_episodes, 'empty', [], all: true),
      ];
      firestore.snapshots[_chapters] = [
        _doc(_chapters, 'changed', ['a', 'b', 'c']),
        _doc(_chapters, 'removed', ['was-watched']),
      ];
      await fixture.startup();
      expect(fixture.episodeCached('changed', 'not-listed'), isTrue);
      expect(fixture.episodeCached('empty', 'not-listed'), isTrue);
      expect(fixture.episodeCached('removed', 'was-watched'), isTrue);
      expect(
        fixture.service.isMangaChapterWatchedCached('removed', 'was-watched'),
        isTrue,
      );

      firestore.snapshots[_episodes] = [
        _doc(_episodes, 'changed', ['b', 7, 'a']),
        _doc(_episodes, 'empty', null),
      ];
      firestore.snapshots[_chapters] = [
        _doc(_chapters, 'changed', ['a', 'b', 'b', null]),
      ];
      await fixture.service.syncAll(includeLibrary: false);
      expect(await fixture.episodes('changed'), orderedEquals(['b', '7', 'a']));
      expect(await fixture.episodes('empty'), isEmpty);
      expect(fixture.episodeCached('changed', 'not-listed'), isFalse);
      expect(fixture.episodeCached('empty', 'not-listed'), isFalse);
      expect(fixture.episodeCached('removed', 'was-watched'), isFalse);
      expect(
        fixture.service.isMangaChapterWatchedCached('removed', 'was-watched'),
        isFalse,
      );
      expect(
        await fixture.service.watchedMangaChapterIds('changed'),
        orderedEquals(['a', 'b', 'null']),
      );
    },
  );

  test(
    'unchanged full snapshots still flush pending local watched writes',
    () async {
      final fixture = _Fixture();
      fixture.firestore.snapshots[_episodes] = [
        _doc(_episodes, 'anime', ['old']),
      ];
      fixture.firestore.snapshots[_chapters] = [
        _doc(_chapters, 'manga', ['old']),
      ];
      await fixture.startup();
      const pendingEpisode = 'animewitcher_account_pending_watched_v1';
      const pendingChapter = 'animewitcher_account_pending_manga_watched_v1';
      await fixture.storage.setString(
        pendingEpisode,
        jsonEncode({
          'episode-write': {
            'anime_id': 'anime',
            'episode_id': 'new',
            'watched': true,
            'owner_uid': _profile.uid,
            'revision': 'fixture-episode-revision',
          },
        }),
      );
      await fixture.storage.setString(
        pendingChapter,
        jsonEncode({
          'chapter-write': {
            'manga_id': 'manga',
            'chapter_ids': ['new'],
            'watched': true,
            'owner_uid': _profile.uid,
            'revision': 'fixture-chapter-revision',
          },
        }),
      );

      await fixture.service.syncAll(includeLibrary: false);
      expect(
        fixture.firestore.writes.map((write) => write.$1),
        unorderedEquals([_episodes, _chapters]),
      );
      for (final write in fixture.firestore.writes) {
        expect(write.$2, ['new']);
        expect(write.$3, isTrue);
      }
      expect(await fixture.episodes('anime'), orderedEquals(['old', 'new']));
      expect(
        await fixture.service.watchedMangaChapterIds('manga'),
        orderedEquals(['old', 'new']),
      );
      expect(fixture.storage.getString(pendingEpisode), isNull);
      expect(fixture.storage.getString(pendingChapter), isNull);
    },
  );

  test(
    'delayed watched snapshots cannot replace a new same-UID session',
    () async {
      final fixture = _Fixture();
      await fixture.startup();
      fixture.firestore.snapshots[_episodes] = [
        _doc(_episodes, 'anime', ['old']),
      ];
      fixture.firestore.snapshots[_chapters] = [
        _doc(_chapters, 'manga', ['old']),
      ];
      final hold = fixture.firestore.hold = _SnapshotHold();
      final oldSync = fixture.service.syncAll(includeLibrary: false);
      await hold.started.future;

      await fixture.service.signOut();
      fixture.secure.seed('new-fixture-token');
      expect((await fixture.service.restoreCachedSession()).isSignedIn, isTrue);
      hold.release.complete();
      await oldSync;
      expect(fixture.episodeCached('anime', 'old'), isFalse);
      expect(
        fixture.service.isMangaChapterWatchedCached('manga', 'old'),
        isFalse,
      );
    },
  );
}
