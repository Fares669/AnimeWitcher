import 'dart:async';
import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
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

const _sessionKey = 'animewitcher_account_session_v1';
const _profileKey = 'animewitcher_account_profile_v1';
const _cachedId = 'cached-id';
const _episodes = 'episodes_watched';
const _chapters = 'chapters_watched';
const _progress = 'continue_watching';
const _collections = [_episodes, _chapters, _progress];
const _rejected = AnimeWitcherAccountException('invalid-session', 'Test 401');
const _profile = AnimeWitcherProfile(
  uid: 'fixture-user',
  documentId: 'fixture-profile',
  signInMethod: AnimeWitcherSignInMethod.email,
  userName: 'Viewer',
);

AnimeWitcherSession _session(String token) => AnimeWitcherSession(
  uid: _profile.uid,
  idToken: token,
  refreshToken: 'refresh-$token',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  signInMethod: _profile.signInMethod,
);

class _Storage extends MemoryStorageService {
  @override
  List<MultimediaItem> getLibraryItems({String? category}) => const [];

  @override
  List<Map<String, dynamic>> getContinueWatching() => const [];

  @override
  Future<void> remove(String key) async {
    settings.remove(key);
  }
}

class _Secure extends SecureTokenStorage {
  _Secure(super.storage);

  final values = <String, String>{
    _sessionKey: jsonEncode(_session(_cachedId).toJson()),
    _profileKey: jsonEncode(_profile.toJson()),
  };
  final writtenTokens = <String>[];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (key == _sessionKey) {
      writtenTokens.add(
        AnimeWitcherSession.fromJson(jsonDecode(value) as Map<String, dynamic>)
            .idToken,
      );
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Auth extends FirebaseAuthRestClient {
  _Auth(Dio dio) : super(dio: dio);

  final inputRefreshTokens = <String>[];
  final firstRefreshStarted = Completer<void>();
  Completer<void>? refreshHold;
  Object? refreshError;

  @override
  Future<AnimeWitcherSession> refresh(AnimeWitcherSession previous) async {
    inputRefreshTokens.add(previous.refreshToken);
    final call = inputRefreshTokens.length;
    if (call == 1) firstRefreshStarted.complete();
    await refreshHold?.future;
    if (refreshError case final error?) throw error;
    return _session('rotated-id-$call');
  }

  @override
  Future<AnimeWitcherSession> signInWithEmail({
    required String email,
    required String password,
    bool requireVerified = true,
  }) async => _session('reauth-id');
}

class _RejectedRequest {
  final started = Completer<void>();
  final release = Completer<void>();
  final retried = Completer<void>();
}

class _Firestore extends FirestoreRestClient {
  _Firestore(Dio dio) : super(dio: dio);

  final rejected = {
    for (final collection in _collections) collection: _RejectedRequest(),
  };
  final reads = <(String, String)>[];
  final profileReads = <String>[];
  String? rejectedReplacementId;

  @override
  Future<List<FirestoreDocument>> listDocuments(
    String collectionPath,
    String idToken, {
    int pageSize = 100,
  }) async {
    final collection = collectionPath.split('/').last;
    final request = rejected[collection]!;
    expect(collectionPath, 'users/${_profile.documentId}/$collection');
    reads.add((collection, idToken));
    if (idToken == _cachedId) {
      if (!request.started.isCompleted) request.started.complete();
      await request.release.future;
      throw _rejected;
    }
    if (!request.retried.isCompleted) request.retried.complete();
    if (idToken == rejectedReplacementId) throw _rejected;
    return const [];
  }

  @override
  Future<List<FirestoreDocument>> queryByStringField({
    required String collectionId,
    required String field,
    required String value,
    required String idToken,
    int limit = 20,
  }) async {
    expect((collectionId, field, value), ('users', 'uid', _profile.uid));
    profileReads.add(idToken);
    return [
      FirestoreDocument(
        id: _profile.documentId,
        path: 'users/${_profile.documentId}',
        fields: {'uid': _profile.uid, 'user_name': 'Verified viewer'},
      ),
    ];
  }

  Future<void> get allInitialStarted =>
      Future.wait(rejected.values.map((request) => request.started.future));

  void rejectOutstanding() {
    for (final request in rejected.values) {
      if (!request.release.isCompleted) request.release.complete();
    }
  }
}

class _Fixture {
  _Fixture() {
    // Fail closed if the real service ever tries an unmocked endpoint.
    final offline = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) => handler.reject(
            DioException(requestOptions: request, error: 'Offline fixture'),
          ),
        ),
      );
    auth = _Auth(offline);
    firestore = _Firestore(offline);
    secure = _Secure(storage);
    service = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: secure,
      auth: auth,
      firestore: firestore,
      cloudStorage: FirebaseStorageRestClient(dio: offline),
      functions: FirebaseFunctionsRestClient(dio: offline),
      diagnostics: AppDiagnostics(sink: const NoopDownloadDiagnosticsV2()),
    );
  }

  final storage = _Storage();
  late final _Secure secure;
  late final _Auth auth;
  late final _Firestore firestore;
  late final AnimeWitcherAccountService service;

  Future<void> restoreCached() async {
    expect((await service.restoreCachedSession()).isSignedIn, isTrue);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'staggered sync 401s rotate and persist the shared credential once',
    () async {
      final fixture = _Fixture();
      await fixture.restoreCached();
      final sync = fixture.service.syncAll(includeLibrary: false);
      await fixture.firestore.allInitialStarted;

      // Confirm the first rotation has completed (not just started) before
      // delivering the other responses from requests sent with the old token.
      for (final collection in _collections) {
        final request = fixture.firestore.rejected[collection]!;
        request.release.complete();
        await request.retried.future;
      }
      await sync;

      expect(fixture.auth.inputRefreshTokens, ['refresh-cached-id']);
      expect(fixture.secure.writtenTokens, ['rotated-id-1']);
      expect(
        fixture.firestore.reads,
        unorderedEquals([
          for (final collection in _collections) (collection, _cachedId),
          for (final collection in _collections) (collection, 'rotated-id-1'),
        ]),
      );
      expect(fixture.service.snapshot.lastSyncAt, isNotNull);

      // An explicit later call remains a fresh data sync, not a cached result.
      final priorReads = fixture.firestore.reads.length;
      await fixture.service.syncAll(includeLibrary: false);
      expect(fixture.firestore.reads, hasLength(priorReads + 3));
      expect(fixture.auth.inputRefreshTokens, ['refresh-cached-id']);
    },
  );

  test('a truly rejected replacement can rotate on the next sync', () async {
    final fixture = _Fixture();
    await fixture.restoreCached();
    fixture.firestore.rejectOutstanding();
    fixture.firestore.rejectedReplacementId = 'rotated-id-1';
    await expectLater(
      fixture.service.syncAll(includeLibrary: false),
      throwsA(same(_rejected)),
    );
    expect(fixture.auth.inputRefreshTokens, [
      'refresh-cached-id',
    ], reason: 'Each failed request permits one retry, not a refresh loop.');
    await fixture.service.syncAll(includeLibrary: false);
    expect(fixture.auth.inputRefreshTokens, [
      'refresh-cached-id',
      'refresh-rotated-id-1',
    ]);
    expect(fixture.secure.writtenTokens, ['rotated-id-1', 'rotated-id-2']);
  });

  test('failed refresh clears its flight and next real sync retries', () async {
    final fixture = _Fixture();
    await fixture.restoreCached();
    fixture.auth.refreshHold = Completer<void>();
    final offline = StateError('Offline during token request');
    fixture.auth.refreshError = offline;
    final expectedFailure = expectLater(
      fixture.service.syncAll(includeLibrary: false),
      throwsA(same(offline)),
    );
    await fixture.firestore.allInitialStarted;
    fixture.firestore.rejectOutstanding();
    await fixture.auth.firstRefreshStarted.future;
    await Future<void>.delayed(Duration.zero);
    fixture.auth.refreshHold!.complete();
    await expectedFailure;
    expect(fixture.auth.inputRefreshTokens, ['refresh-cached-id']);
    expect(fixture.secure.writtenTokens, isEmpty);
    expect(fixture.service.snapshot.isSignedIn, isTrue);

    fixture.auth.refreshError = null;
    await fixture.service.syncAll(includeLibrary: false);
    expect(fixture.auth.inputRefreshTokens, [
      'refresh-cached-id',
      'refresh-cached-id',
    ]);
    expect(fixture.secure.writtenTokens, ['rotated-id-2']);
  });

  test(
    'a late rejection cannot rotate or use same-UID reauth credentials',
    () async {
      final fixture = _Fixture();
      await fixture.restoreCached();
      final oldSync = expectLater(
        fixture.service.syncAll(includeLibrary: false),
        throwsA(
          isA<AnimeWitcherAccountException>().having(
            (error) => error.code,
            'code',
            'session-changed',
          ),
        ),
      );
      await fixture.firestore.allInitialStarted;
      await fixture.service.signOut();
      expect(fixture.service.snapshot.isSignedIn, isFalse);
      await fixture.service.signInWithEmail(
        email: 'viewer@example.invalid',
        password: 'mock-password',
      );
      expect(fixture.service.snapshot.isSignedIn, isTrue);

      fixture.firestore.rejectOutstanding();
      await oldSync;
      expect(fixture.firestore.profileReads, ['reauth-id']);
      expect(fixture.auth.inputRefreshTokens, isEmpty);
      expect(fixture.secure.writtenTokens, ['reauth-id']);
      expect(
        fixture.firestore.reads.where((read) => read.$2 == 'reauth-id'),
        hasLength(3),
      );
    },
  );
}
