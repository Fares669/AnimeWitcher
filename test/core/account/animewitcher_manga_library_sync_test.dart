import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

final class _Storage extends MemoryStorageService {
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

final class _Write {
  const _Write(this.path, this.fields, this.serverTimestampFields);

  final String path;
  final Map<String, dynamic> fields;
  final Set<String> serverTimestampFields;
}

final class _Firestore extends FirestoreRestClient {
  final List<_Write> writes = <_Write>[];
  final List<String> deletes = <String>[];

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
}

Future<AnimeWitcherAccountService> _signedInService(_Firestore firestore) async {
  final storage = _Storage();
  final secure = _SecureStorage(storage);
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
  secure.values['animewitcher_account_session_v1'] = jsonEncode(session.toJson());
  secure.values['animewitcher_account_profile_v1'] = jsonEncode(profile.toJson());

  final service = AnimeWitcherAccountService(
    storage: storage,
    secureStorage: secure,
    firestore: firestore,
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
);

void main() {
  test('manga list write uses user_manga and official fields', () async {
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
    expect(listWrite.fields, <String, dynamic>{
      'manga_id': 'm1',
      'type': 'watching',
      'views': 0,
    });
    expect(listWrite.serverTimestampFields, <String>{'date'});
    expect(
      firestore.writes.any((write) => write.path.contains('user_anime')),
      isFalse,
    );
  });

  test('manga favorite write uses fav_manga and official fields', () async {
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
    expect(favorite.fields, <String, dynamic>{
      'manga_id': 'm1',
      'views': 0,
    });
    expect(favorite.serverTimestampFields, <String>{'date'});
    expect(
      firestore.writes.any((write) => write.path.contains('fav_anime')),
      isFalse,
    );
  });

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
}
