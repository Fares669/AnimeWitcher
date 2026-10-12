import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/utils/episode_label.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _Storage extends MemoryStorageService {
  final rows = <Map<String, dynamic>>[];
  @override
  String? getString(String key) => settings[key] as String?;
  @override
  Future<void> setString(String key, String? value) async => settings[key] = value;
  @override
  Future<void> remove(String key) async => settings.remove(key);
  @override
  List<Map<String, dynamic>> getContinueWatching() => rows;
  @override
  Future<void> markContinueWatchingItemSynced(String url, {required String accountUid, required int syncedAt}) async {}
  @override
  Future<void> saveContinueWatchingProgress(MultimediaItem item, int positionMillis, int durationMillis, {
    String? lastStreamUrl, String? lastEpisodeUrl, int? season, int? episode,
    String? episodeTitle, String? episodeServerName, String? episodePosterUrl,
    int? progressPercent, int? timestamp, String? syncedAccountUid, int? syncedAt,
  }) async {
    rows.removeWhere((row) => row['url'] == item.url);
    rows.add({
      'title': item.title, 'url': item.url, 'posterUrl': item.posterUrl,
      'contentType': item.contentType.name, 'provider': item.provider,
      'position': positionMillis, 'duration': durationMillis,
      'lastEpisodeUrl': lastEpisodeUrl, 'episode': episode,
      'episodeTitle': episodeTitle, 'episodeServerName': episodeServerName,
      'episodePosterUrl': episodePosterUrl, 'timestamp': timestamp,
    });
  }
}

class _Secure extends SecureTokenStorage {
  _Secure(super.storage);
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Firestore extends FirestoreRestClient {
  final writes = <String, Map<String, dynamic>>{};
  List<FirestoreDocument> remote = [];
  @override
  Future<FirestoreDocument> setDocument(String path, Map<String, dynamic> fields, String idToken, {bool merge = true}) async {
    writes[path] = Map.of(fields);
    return FirestoreDocument(id: path.split('/').last, path: path, fields: fields);
  }
  @override
  Future<void> setDocumentWithServerTimestamps(String path, Map<String, dynamic> fields, String idToken, {required Set<String> serverTimestampFields, bool merge = true}) async => writes[path] = Map.of(fields);
  @override
  Future<List<FirestoreDocument>> listDocuments(String path, String idToken, {int pageSize = 100}) async => remote;
  @override
  Future<FirestoreDocument?> getDocument(String path, String idToken) async => null;
}

Future<AnimeWitcherAccountService> _account(_Storage storage, _Firestore firestore) async {
  final secure = _Secure(storage);
  final session = AnimeWitcherSession(uid: 'uid', idToken: 'test', refreshToken: 'test', expiresAt: DateTime.now().add(const Duration(hours: 1)), signInMethod: AnimeWitcherSignInMethod.email);
  const profile = AnimeWitcherProfile(documentId: 'profile', uid: 'uid', signInMethod: AnimeWitcherSignInMethod.email, userName: 'Viewer');
  secure.values['animewitcher_account_session_v1'] = jsonEncode(session.toJson());
  secure.values['animewitcher_account_profile_v1'] = jsonEncode(profile.toJson());
  final service = AnimeWitcherAccountService(storage: storage, secureStorage: secure, firestore: firestore);
  await service.restoreCachedSession();
  expect(service.isSignedIn, isTrue);
  return service;
}

final _item = MultimediaItem(title: 'Show', url: 'https://animewitcher.com/watch/show', posterUrl: '', contentType: MultimediaContentType.anime, provider: AnimeWitcherAccountService.animeWitcherProvider);

void main() {
  for (final name in ['الحلقة ٢', 'الحلقة ٢.٥', 'الحلقة الخاصة: العودة / الجزء؟']) {
    test('offline saved original label uploads unchanged and online import keeps label $name', () async {
      final local = _Storage();
      local.rows.add({
        'title': _item.title, 'url': _item.url, 'posterUrl': '',
        'contentType': 'anime', 'provider': _item.provider,
        'position': 30000, 'duration': 100000,
        'lastEpisodeUrl': 'show|ep2', 'episode': 2,
        'episodeTitle': 'Creative title', 'episodeServerName': name,
        'episodeServerNumber': '٢.٥',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final firestore = _Firestore();
      final service = await _account(local, firestore);
      await service.syncContinueWatching();
      final fields = firestore.writes['users/profile/continue_watching/show']!;
      expect(fields['episode_name'], name);
      expect(fields['episode_title'], 'Creative title');
      expect(fields['episode_server_name'], name);
      expect(fields['episode_number_raw'], '٢.٥');
      expect(fields['episode_number'], 2);
      final imported = _Storage();
      firestore.remote = [FirestoreDocument(id: 'show', path: 'users/profile/continue_watching/show', fields: fields)];
      final otherDevice = await _account(imported, firestore);
      await otherDevice.syncContinueWatching();
      expect(imported.rows.single['episodeServerNumber'], '٢.٥');
      final history = HistoryItem.fromMap(imported.rows.single);
      expect(history.episodeTitle, 'Creative title');
      expect(history.episodeServerName, name);
      expect(continueWatchingPrimaryLabel(episode: history.episode, isArabic: true, episodeTitle: history.episodeTitle, episodeServerName: history.episodeServerName), name);
    });
  }

  test('official legacy cloud episode_name remains the original server label', () async {
    const original = 'الحلقة ٢.٥';
    final storage = _Storage();
    final firestore = _Firestore()..remote = [FirestoreDocument(id: 'show', path: 'users/profile/continue_watching/show', fields: {
      'anime_id': 'show', 'episode_id': 'ep2', 'episode_number': 2,
      'episode_name': original, 'episode_url': 'show|ep2', 'position': 30000,
      'duration': 100000, 'progress': 30,
      'animewitcher_item': _item.toJson(),
    })];
    final account = await _account(storage, firestore);
    await account.syncContinueWatching();
    final history = HistoryItem.fromMap(storage.rows.single);
    expect(history.episodeServerName, original);
    expect(continueWatchingPrimaryLabel(episode: history.episode, isArabic: true, episodeServerName: history.episodeServerName), original);
  });
}
