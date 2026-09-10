import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firebase_auth_rest_client.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

/// Keeps tokens in memory so a session can be planted before the service
/// restores one.
class _MemorySecureStorage extends SecureTokenStorage {
  _MemorySecureStorage(super.storage);

  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Serves one published comment, and refuses every authenticated read.
class _CommentsOnlyFirestore extends FirestoreRestClient {
  _CommentsOnlyFirestore();

  int likeLookups = 0;

  @override
  Future<List<FirestoreDocument>> queryPublishedComments(
    String collectionPath, {
    String orderField = 'date',
    bool descending = true,
    FirestoreDocument? startAfter,
    int limit = 20,
  }) async {
    return <FirestoreDocument>[
      FirestoreDocument(
        id: 'c1',
        path: '$collectionPath/c1',
        fields: <String, dynamic>{
          // Comments read 'comment'; reviews read 'review_text'. One fake
          // serves both so the reviews case exercises the same path.
          'comment': 'تعليق منشور',
          'review_text': 'تعليق منشور',
          'user_id': 'someone-else',
          'published': true,
        },
      ),
    ];
  }

  @override
  Future<FirestoreDocument?> getDocument(String path, String idToken) async {
    likeLookups += 1;
    throw StateError('should not be reached with an unusable session');
  }
}

/// A session that cannot be refreshed, which is what an expired token on a
/// build with no keys — or a moment offline — looks like from here.
class _RefusingAuth extends FirebaseAuthRestClient {
  _RefusingAuth();

  @override
  Future<AnimeWitcherSession> refresh(
    AnimeWitcherSession session, {
    bool force = false,
  }) async {
    throw const AnimeWitcherAccountException(
      'invalid-session',
      'The session could not be refreshed.',
    );
  }

  @override
  Future<Map<String, dynamic>> lookup(String idToken) async {
    throw const AnimeWitcherAccountException(
      'invalid-session',
      'The session could not be looked up.',
    );
  }
}

void main() {
  late _CommentsOnlyFirestore firestore;
  late AnimeWitcherAccountService service;

  setUp(() async {
    final storage = MemoryStorageService();
    final secure = _MemorySecureStorage(storage);

    // Signed in as far as the device is concerned: a stored profile and a
    // token that expired an hour ago.
    final session = AnimeWitcherSession(
      uid: 'uid-1',
      idToken: 'stale',
      refreshToken: 'also-stale',
      expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
      signInMethod: AnimeWitcherSignInMethod.google,
    );
    const profile = AnimeWitcherProfile(
      documentId: 'user-doc',
      uid: 'uid-1',
      signInMethod: AnimeWitcherSignInMethod.google,
      userName: 'Me',
    );
    secure.values['animewitcher_account_session_v1'] = jsonEncode(
      session.toJson(),
    );
    secure.values['animewitcher_account_profile_v1'] = jsonEncode(
      profile.toJson(),
    );

    firestore = _CommentsOnlyFirestore();
    service = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: secure,
      firestore: firestore,
      auth: _RefusingAuth(),
    );
    await service.restoreSession();
  });

  test('comments still load when the session cannot be authorised', () async {
    // The like markers are an optional enrichment on top of a list that is
    // public and already fetched. Getting a token for them fails for reasons
    // that have nothing to do with the comments — an expired session, a build
    // with no keys, a moment offline — and it used to take the whole list
    // down with it, leaving "could not load comments" over a screen whose
    // data had arrived.
    final page = await service.loadComments(
      const AnimeWitcherCommentTarget(
        collectionPath: 'anime_list/a/comments',
        sourceDocumentPath: 'anime_list/a',
        title: 'Thunder 3',
      ),
    );

    expect(page.items, hasLength(1));
    expect(page.items.single.text, 'تعليق منشور');
  });

  test('the markers are simply absent, not wrong', () async {
    final page = await service.loadComments(
      const AnimeWitcherCommentTarget(
        collectionPath: 'anime_list/a/comments',
        sourceDocumentPath: 'anime_list/a',
        title: 'Thunder 3',
      ),
    );

    // Unknown reads as not liked rather than as liked, so nothing claims a
    // like the viewer never gave.
    expect(page.items.single.likedByMe, isFalse);
  });

  test('reviews come back too, being the same collection read', () async {
    final page = await service.loadComments(
      const AnimeWitcherCommentTarget(
        collectionPath: 'anime_list/a/reviews',
        sourceDocumentPath: 'anime_list/a',
        title: 'Thunder 3',
        kind: AnimeWitcherSocialKind.reviews,
      ),
    );
    expect(page.items, hasLength(1));
  });
}
