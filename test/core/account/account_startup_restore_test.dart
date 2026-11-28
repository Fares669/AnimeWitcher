import 'dart:async';
import 'dart:convert';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firebase_auth_rest_client.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

class _AccountStorage extends MemoryStorageService {
  @override
  String? getString(String key) => null;

  @override
  Future<void> remove(String key) async {
    settings.remove(key);
  }
}

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

class _BlockingAuth extends FirebaseAuthRestClient {
  final Completer<void> lookupStarted = Completer<void>();
  final Completer<Map<String, dynamic>> lookupResult =
      Completer<Map<String, dynamic>>();

  @override
  Future<Map<String, dynamic>> lookup(String idToken) {
    if (!lookupStarted.isCompleted) lookupStarted.complete();
    return lookupResult.future;
  }
}

AnimeWitcherSession _validSession() => AnimeWitcherSession(
  uid: 'uid-1',
  idToken: 'still-valid-token',
  refreshToken: 'refresh-token',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  signInMethod: AnimeWitcherSignInMethod.email,
  email: 'viewer@example.com',
  providerIds: const <String>['password'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cached signed-in account becomes available before remote lookup finishes',
    () async {
      final storage = _AccountStorage();
      final secure = _MemorySecureStorage(storage);
      final auth = _BlockingAuth();

      const profile = AnimeWitcherProfile(
        documentId: 'profile-1',
        uid: 'uid-1',
        signInMethod: AnimeWitcherSignInMethod.email,
        email: 'viewer@example.com',
        userName: 'Viewer',
        providerIds: <String>['password'],
      );
      secure.values['animewitcher_account_session_v1'] = jsonEncode(
        _validSession().toJson(),
      );
      secure.values['animewitcher_account_profile_v1'] = jsonEncode(
        profile.toJson(),
      );

      final service = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: secure,
        auth: auth,
      );
      final container = ProviderContainer(
        overrides: [
          animeWitcherAccountServiceProvider.overrideWithValue(service),
        ],
      );

      addTearDown(() async {
        if (!auth.lookupResult.isCompleted) {
          auth.lookupResult.completeError(
            const AnimeWitcherAccountException(
              'invalid-session',
              'Test lookup released during teardown.',
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);
        container.dispose();
      });

      final restored = await container
          .read(animeWitcherAccountControllerProvider.future)
          .timeout(const Duration(milliseconds: 250));

      expect(restored.isSignedIn, isTrue);
      expect(restored.profile?.userName, 'Viewer');

      // Verification must still happen; it just must not hold the cached
      // account hostage behind the network on every launch.
      await auth.lookupStarted.future.timeout(
        const Duration(milliseconds: 250),
      );
      expect(auth.lookupResult.isCompleted, isFalse);
    },
  );

  test(
    'startup verifies a cached credential even without a cached profile',
    () async {
      final storage = _AccountStorage();
      final secure = _MemorySecureStorage(storage);
      final auth = _BlockingAuth();
      secure.values['animewitcher_account_session_v1'] = jsonEncode(
        _validSession().toJson(),
      );
      final service = AnimeWitcherAccountService(
        storage: storage,
        secureStorage: secure,
        auth: auth,
      );
      final container = ProviderContainer(
        overrides: [
          animeWitcherAccountServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(() async {
        if (!auth.lookupResult.isCompleted) {
          auth.lookupResult.complete(<String, dynamic>{'emailVerified': false});
        }
        await Future<void>.delayed(Duration.zero);
        container.dispose();
      });

      final restored = await container.read(
        animeWitcherAccountControllerProvider.future,
      );
      expect(restored.isSignedIn, isFalse);
      expect(container.read(accountDataRevisionProvider), 0);
      await auth.lookupStarted.future.timeout(const Duration(seconds: 1));
      auth.lookupResult.complete(<String, dynamic>{'emailVerified': false});
      await Future<void>.delayed(Duration.zero);
      expect(container.read(accountDataRevisionProvider), 1);
      expect(secure.values['animewitcher_account_session_v1'], isNull);
    },
  );
}
