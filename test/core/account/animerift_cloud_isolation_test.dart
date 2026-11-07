import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Storage extends StorageService {
  final values = <String, String>{};
  int nativeWrites = 0;

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> markLibraryItemSynced(
    String url, {
    required String accountUid,
    required int syncedAt,
  }) async {
    nativeWrites++;
  }

  @override
  Future<void> markHistoryItemSynced(
    String url, {
    required String accountUid,
    required int syncedAt,
  }) async {
    nativeWrites++;
  }
}

class _Secure extends SecureTokenStorage {
  _Secure(super.storage);

  final values = <String, String>{};

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

class _Firestore extends FirestoreRestClient {
  final writes = <String>[];

  @override
  Future<void> setDocumentWithServerTimestamps(
    String path,
    Map<String, dynamic> fields,
    String idToken, {
    required Set<String> serverTimestampFields,
    bool merge = true,
  }) async {
    writes.add(path);
  }

  @override
  Future<List<FirestoreDocument>> listDocuments(
    String collectionPath,
    String idToken, {
    int pageSize = 100,
  }) async => <FirestoreDocument>[];

  @override
  Future<void> deleteDocument(String path, String idToken) async {
    writes.add(path);
  }
}

void main() {
  test(
    'signed-in Witcher cloud accepts native but rejects Rift item writes',
    () async {
      final storage = _Storage();
      final secure = _Secure(storage);
      final firestore = _Firestore();
      final session = AnimeWitcherSession(
        uid: 'owner-1',
        idToken: 'test-token',
        refreshToken: 'test-refresh',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        signInMethod: AnimeWitcherSignInMethod.email,
        email: 'test@example.com',
      );
      const profile = AnimeWitcherProfile(
        documentId: 'profile-1',
        uid: 'owner-1',
        signInMethod: AnimeWitcherSignInMethod.email,
        email: 'test@example.com',
        userName: 'Test',
      );
      secure.values['animewitcher_account_session_v1'] = jsonEncode(
        session.toJson(),
      );
      secure.values['animewitcher_account_profile_v1'] = jsonEncode(
        profile.toJson(),
      );
      final service = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: secure,
        firestore: firestore,
      );
      await service.restoreCachedSession();
      expect(service.isSignedIn, isTrue);

      const url = 'https://animewitcher.com/watch/same-id';
      final native = MultimediaItem(title: 'Witcher', url: url, posterUrl: '');
      final rift = MultimediaItem(
        title: 'Rift',
        url: url,
        posterUrl: '',
        provider: animeRiftProviderId,
      );
      await service.saveLibraryItem(native, LibraryCategory.planToWatch);
      expect(firestore.writes, contains('users/profile-1/user_anime/same-id'));
      final baselineWrites = firestore.writes.length;
      final baselineNative = storage.nativeWrites;

      await service.saveLibraryItem(
        rift,
        LibraryCategory.watching,
        favorite: true,
      );
      await service.recordLastWatched(item: rift);
      await service.saveProgress(
        item: rift,
        position: 15,
        duration: 30,
        episodeUrl: 'same-id|episode-1',
      );
      await service.saveContinueWatchingProgress(
        item: rift,
        position: 15,
        duration: 30,
        episodeUrl: 'same-id|episode-1',
      );

      final riftManga = rift.copyWith(
        url: 'https://animewitcher.com/manga/same-id',
        contentType: MultimediaContentType.manga,
      );
      await service.saveMangaLibraryItem(
        riftManga,
        LibraryCategory.planToWatch,
        favorite: true,
      );

      expect(firestore.writes.length, baselineWrites);
      expect(storage.nativeWrites, baselineNative);
    },
  );
}
