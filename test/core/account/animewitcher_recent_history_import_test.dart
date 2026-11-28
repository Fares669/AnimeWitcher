import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

const _uid = 'fixture-uid';
const _profileId = 'fixture-profile';
const _recentPath = 'users/$_profileId/last_watched';

String _url(String id) => 'https://animewitcher.com/watch/$id';
String _alias(String id) => 'http://www.animewitcher.com/watch/$id?old=1';

Map<String, dynamic> _row(
  String url, {
  int timestamp = 100,
  int position = 77,
  String title = 'canonical row',
  String? episode,
}) => {
  'url': url,
  'timestamp': timestamp,
  'position': position,
  'duration': 300,
  'title': title,
  'posterUrl': '',
  'contentType': 'anime',
  'lastEpisodeUrl': ?episode,
};

FirestoreDocument _recent(String id, int date) => FirestoreDocument(
  id: id,
  path: '$_recentPath/$id',
  fields: <String, dynamic>{'anime_id': id, 'date': date},
);

class _UrlReads extends MapBase<String, dynamic> {
  _UrlReads(this.source, this.onUrl);
  final Map<String, dynamic> source;
  final void Function() onUrl;
  @override
  dynamic operator [](Object? key) {
    if (key == 'url') onUrl();
    return source[key];
  }

  @override
  void operator []=(String key, dynamic value) => source[key] = value;
  @override
  Iterable<String> get keys => source.keys;
  @override
  dynamic remove(Object? key) => source.remove(key);
  @override
  void clear() => source.clear();
}

class _Storage extends StorageService {
  final _settings = <String, String?>{};
  Future<void> Function(String)? afterMark;

  @override
  String? getString(String key) => _settings[key];
  @override
  Future<void> setString(String key, String? value) async =>
      _settings[key] = value;
  @override
  Future<void> remove(String key) async => _settings.remove(key);
  @override
  Future<void> markHistoryItemSynced(
    String url, {
    required String accountUid,
    required int syncedAt,
  }) async {
    await super.markHistoryItemSynced(
      url,
      accountUid: accountUid,
      syncedAt: syncedAt,
    );
    await afterMark?.call(url);
  }
}

class _Secure extends SecureTokenStorage {
  _Secure(super.storage);
  final values = <String, String>{};

  void seed() {
    values['animewitcher_account_session_v1'] = jsonEncode(
      AnimeWitcherSession(
        uid: _uid,
        idToken: 'local-fixture',
        refreshToken: 'local-fixture',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        signInMethod: AnimeWitcherSignInMethod.email,
      ).toJson(),
    );
    values['animewitcher_account_profile_v1'] = jsonEncode(
      const AnimeWitcherProfile(
        documentId: _profileId,
        uid: _uid,
        signInMethod: AnimeWitcherSignInMethod.email,
        userName: 'Viewer',
      ).toJson(),
    );
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Cloud extends FirestoreRestClient {
  final remote = <FirestoreDocument>[];
  final calls = <String>[];
  Future<List<FirestoreDocument>> Function()? onList;
  Future<FirestoreDocument?> Function(String)? onGet;
  bool deleteOffline = false;

  @override
  Future<List<FirestoreDocument>> listDocuments(
    String path,
    String idToken, {
    int pageSize = 100,
  }) async {
    expect(path, _recentPath);
    expect(idToken, 'local-fixture');
    calls.add('list:$path');
    final onListNow = onList;
    return onListNow == null ? [...remote] : onListNow();
  }

  @override
  Future<FirestoreDocument?> getDocument(String path, String idToken) async {
    calls.add('get:$path');
    return onGet?.call(path);
  }

  @override
  Future<void> deleteDocument(String path, String idToken) async {
    calls.add('delete:$path');
    if (deleteOffline) throw StateError('fixture offline');
    remote.removeWhere((row) => row.path == path);
  }
}

Future<
  ({
    _Storage storage,
    _Secure secure,
    _Cloud cloud,
    Box<dynamic> box,
    AnimeWitcherAccountService account,
  })
>
_fixture({bool signedIn = true}) async {
  final dir = await Directory.systemTemp.createTemp('aw-history-import-');
  addTearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });
  Hive.init(dir.path);
  final storage = _Storage();
  await storage.initHistory();
  final box = Hive.box<dynamic>(StorageService.kHistoryBox);
  final secure = _Secure(storage);
  final cloud = _Cloud();
  final account = AnimeWitcherAccountService(
    storage: storage,
    secureStorage: secure,
    firestore: cloud,
  );
  if (signedIn) {
    secure.seed();
    await account.restoreCachedSession();
    expect(account.isSignedIn, isTrue);
  }
  return (
    storage: storage,
    secure: secure,
    cloud: cloud,
    box: box,
    account: account,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real account Recent import avoids rescanning unrelated Hive rows', () async {
    final f = await _fixture();
    const untouched = 1200;
    const remoteRows = 160;
    var reads = 0;
    final rows = <String, dynamic>{
      for (var i = 0; i < untouched; i++)
        _url('noise-$i'): _UrlReads(_row(_url('noise-$i')), () => reads++),
      for (var i = 0; i < remoteRows; i++)
        (i.isEven ? _url('target-$i') : _alias('target-$i')): _row(
          i.isEven ? _url('target-$i') : _alias('target-$i'),
          position: i + 10,
        ),
    };
    await f.box.putAll(rows);
    // The real Hive box retains each instrumentation object in its in-memory
    // index. Only noise-row URL lookups are counted, never updated row writes.
    expect(f.box.get(_url('noise-0')), same(rows[_url('noise-0')]));
    f.storage.getWatchHistory();
    f.cloud.remote.addAll(
      List.generate(remoteRows, (i) => _recent('target-$i', 1000 + i)),
    );
    reads = 0;
    await f.account.syncRecentWatched();
    expect(reads, untouched);
    expect(f.cloud.calls, ['list:$_recentPath']);
    expect(f.box.length, rows.length);
    for (var i = 0; i < remoteRows; i++) {
      final canonical = f.box.get(_url('target-$i')) as Map<dynamic, dynamic>;
      expect(canonical['position'], i + 10);
      expect(canonical['timestamp'], 1000 + i);
      expect(canonical['animeWitcherSyncedUid'], _uid);
      expect(canonical['animeWitcherSyncedAt'], 1000 + i);
      expect(f.box.containsKey(_alias('target-$i')), false);
    }
    final view = f.storage.getWatchHistory();
    expect(view.take(remoteRows).map((r) => r['url']), [
      for (var i = remoteRows - 1; i >= 0; i--) _url('target-$i'),
    ]);
  });

  test('keeps canonical metadata, alias positions, and episode keys', () async {
    final f = await _fixture();
    const episode = 'one-episode-5';
    const former = 'one-episode-4';
    await f.box.putAll({
      _url('one'): _row(_url('one'), episode: episode),
      _alias('one'): _row(
        _alias('one'),
        timestamp: 500,
        position: 191,
        episode: episode,
        title: 'alias row',
      ),
      'EP_$former': _row(_alias('one'), episode: former, position: 31),
      'EP_$episode': _row(_alias('one'), episode: episode, position: 80),
      _alias('two'): _row(
        _alias('two'),
        position: 233,
        title: 'only alias row',
      ),
    });
    f.cloud.remote.addAll([_recent('two', 1001), _recent('one', 1000)]);
    await f.account.syncRecentWatched();
    final one = f.box.get(_url('one')) as Map<dynamic, dynamic>;
    final two = f.box.get(_url('two')) as Map<dynamic, dynamic>;
    expect(one['title'], 'canonical row');
    expect(one['position'], 191);
    expect(two['title'], 'only alias row');
    expect(two['position'], 233);
    expect(f.box.containsKey(_alias('one')), false);
    expect(f.box.containsKey(_alias('two')), false);
    final priorEp = f.box.get('EP_$former') as Map<dynamic, dynamic>;
    final currentEp = f.box.get('EP_$episode') as Map<dynamic, dynamic>;
    expect(priorEp['position'], 31);
    expect(priorEp['animeWitcherSyncedUid'], isNull);
    expect(currentEp['position'], 191);
    expect(currentEp['timestamp'], 1000);
    expect(currentEp['animeWitcherSyncedUid'], _uid);
  });

  test(
    'retains fresh key identity and direct alias additions during import',
    () async {
      final f = await _fixture();
      const oldSlot = 'legacy-slot';
      await f.box.putAll({
        _url('one'): _row(_url('one')),
        _url('two'): _row(_url('two')),
        _alias('three'): _row(_alias('three')),
        oldSlot: _row(_alias('two'), position: 59),
      });
      f.cloud.remote.addAll([
        _recent('one', 1002),
        _recent('two', 1001),
        _recent('three', 1000),
      ]);
      f.storage.afterMark = (url) async {
        if (url != _url('one')) return;
        await f.box.put(oldSlot, _row(_alias('unrelated')));
        await f.box.put('inserted-alias', _row(_alias('two')));
        await f.storage.removeFromHistory(_url('three'));
      };
      await f.account.syncRecentWatched();
      expect(
        (f.box.get(oldSlot) as Map<dynamic, dynamic>)['url'],
        _alias('unrelated'),
      );
      expect(f.box.containsKey('inserted-alias'), false);
      expect(f.box.containsKey(_alias('three')), false);
      expect(f.box.containsKey(_url('three')), false);
      expect(
        (f.box.get(_url('two')) as Map<dynamic, dynamic>)['timestamp'],
        1001,
      );
    },
  );

  test(
    'without a session the import leaves local history and cloud untouched',
    () async {
      final f = await _fixture(signedIn: false);
      await f.box.put(_url('guest'), _row(_url('guest')));
      f.cloud.remote.add(_recent('guest', 1000));
      await f.account.syncRecentWatched();
      expect(f.cloud.calls, isEmpty);
      expect(
        (f.box.get(_url('guest')) as Map<dynamic, dynamic>)['timestamp'],
        100,
      );
    },
  );

  test(
    'flushes pending deletion and known writes before missing item fetch',
    () async {
      final f = await _fixture();
      await f.box.putAll({
        _url('one'): _row(_url('one')),
        _url('two'): _row(_url('two')),
      });
      f.cloud.remote.addAll([
        _recent('deleted', 1003),
        _recent('one', 1002),
        _recent('missing', 1001),
        _recent('two', 1000),
      ]);
      f.cloud.deleteOffline = true;
      await expectLater(
        f.account.removeLastWatched(_url('deleted')),
        throwsStateError,
      );
      f.cloud.deleteOffline = false;
      f.cloud.calls.clear();
      f.cloud.onGet = (path) async {
        expect(path, 'anime_list/missing');
        expect(
          (f.box.get(_url('one')) as Map<dynamic, dynamic>)['timestamp'],
          1002,
        );
        expect(
          (f.box.get(_url('two')) as Map<dynamic, dynamic>)['timestamp'],
          100,
        );
        return FirestoreDocument(
          id: 'missing',
          path: path,
          fields: const <String, dynamic>{'name': 'Imported'},
        );
      };
      await f.account.syncRecentWatched();
      expect(f.cloud.calls, [
        'delete:$_recentPath/deleted',
        'list:$_recentPath',
        'get:anime_list/missing',
      ]);
      expect(f.box.containsKey(_url('deleted')), false);
      expect(
        (f.box.get(_url('missing')) as Map<dynamic, dynamic>)['title'],
        'Imported',
      );
      expect(
        (f.box.get(_url('two')) as Map<dynamic, dynamic>)['timestamp'],
        1000,
      );
    },
  );

  test('sign-out stops the current batch before later rows', () async {
    final f = await _fixture();
    await f.box.putAll({
      _url('one'): _row(_url('one')),
      _url('two'): _row(_url('two')),
    });
    f.cloud.remote.addAll([_recent('one', 1001), _recent('two', 1000)]);
    final started = Completer<void>();
    final proceed = Completer<void>();
    f.storage.afterMark = (url) async {
      if (url != _url('one')) return;
      started.complete();
      await proceed.future;
    };
    final sync = f.account.syncRecentWatched();
    await started.future;
    await f.account.signOut();
    proceed.complete();
    await sync;
    expect((f.box.get(_url('two')) as Map<dynamic, dynamic>)['timestamp'], 100);
  });

  test(
    'same-profile reauthentication does not adopt an older response',
    () async {
      final f = await _fixture();
      await f.box.put(_url('one'), _row(_url('one')));
      final requested = Completer<void>();
      final response = Completer<List<FirestoreDocument>>();
      f.cloud.onList = () {
        requested.complete();
        return response.future;
      };

      final pending = f.account.syncRecentWatched();
      await requested.future;
      await f.account.signOut();
      f.secure.seed();
      await f.account.restoreCachedSession();
      expect(f.account.isSignedIn, isTrue);
      response.complete([_recent('one', 1000)]);
      await pending;

      final row = f.box.get(_url('one')) as Map<dynamic, dynamic>;
      expect(row['timestamp'], 100);
      expect(row['animeWitcherSyncedUid'], isNull);
    },
  );
}
