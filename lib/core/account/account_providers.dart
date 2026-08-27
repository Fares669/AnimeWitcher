import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/secure_token_storage.dart';
import '../storage/storage_service.dart';
import 'animewitcher_account_models.dart';
import 'animewitcher_account_service.dart';

final animeWitcherAccountServiceProvider =
    Provider<AnimeWitcherAccountService>((ref) {
      return AnimeWitcherAccountService(
        storage: ref.watch(storageServiceProvider),
        secureStorage: ref.watch(secureTokenStorageProvider),
      );
    });

final accountDataRevisionProvider =
    NotifierProvider<AccountDataRevision, int>(AccountDataRevision.new);

class AccountDataRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final animeWitcherAccountControllerProvider = AsyncNotifierProvider<
  AnimeWitcherAccountController,
  AnimeWitcherAccountSnapshot
>(AnimeWitcherAccountController.new);

class AnimeWitcherAccountController
    extends AsyncNotifier<AnimeWitcherAccountSnapshot> {
  AnimeWitcherAccountService get _service =>
      ref.read(animeWitcherAccountServiceProvider);

  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    final restored = await _service.restoreSession();
    if (restored.isSignedIn) {
      unawaited(
        Future<void>.delayed(Duration.zero, () {
          ref.read(accountDataRevisionProvider.notifier).bump();
        }),
      );
    }
    return restored;
  }

  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    await _run(() => _service.signInWithEmail(email: email, password: password));
  }

  Future<void> signInWithGoogle() async {
    await _run(_service.signInWithGoogle);
  }

  Future<void> createEmailAccount({
    required String userName,
    required String email,
    required String password,
  }) async {
    await _run(() async {
      await _service.createEmailAccount(
        userName: userName,
        email: email,
        password: password,
      );
      return _service.snapshot;
    }, bumpData: false);
  }

  Future<void> resendEmailVerification({
    required String email,
    required String password,
  }) async {
    await _run(() async {
      await _service.resendEmailVerification(
        email: email,
        password: password,
      );
      return _service.snapshot;
    }, bumpData: false);
  }

  Future<void> sendPasswordResetEmail(String email) async {
    await _run(() async {
      await _service.sendPasswordResetEmail(email);
      return _service.snapshot;
    }, bumpData: false);
  }

  Future<void> updateProfile({
    required String userName,
    required String bio,
    required String country,
    required String birthYear,
    Uint8List? avatarBytes,
    Uint8List? coverBytes,
  }) async {
    await _run(
      () => _service.updateProfile(
        userName: userName,
        bio: bio,
        country: country,
        birthYear: birthYear,
        avatarBytes: avatarBytes,
        coverBytes: coverBytes,
      ),
    );
  }

  Future<void> updatePrivacySettings(
    AnimeWitcherPrivacySettings settings,
  ) async {
    await _run(() => _service.updatePrivacySettings(settings));
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _run(
      () => _service.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
      ),
      bumpData: false,
    );
  }

  Future<void> requestEmailChange({
    required String newEmail,
    required String currentPassword,
  }) async {
    await _run(
      () => _service.requestEmailChange(
        newEmail: newEmail,
        currentPassword: currentPassword,
      ),
    );
  }

  Future<void> deleteAccount() async {
    await _run(_service.deleteAccount);
  }

  Future<void> syncNow() async {
    await _run(() async {
      await _service.syncAll();
      return _service.snapshot;
    });
  }

  Future<void> signOut() async {
    await _run(() async {
      await _service.signOut();
      return _service.snapshot;
    });
  }

  Future<void> _run(
    Future<AnimeWitcherAccountSnapshot> Function() operation, {
    bool bumpData = true,
  }) async {
    final previous = state.asData?.value ?? _service.snapshot;
    // Keep the authenticated account visible while a manual sync or sign-out
    // is in flight. Replacing a signed-in value with a bare AsyncLoading would
    // briefly swap the account screen back to the login form.
    if (!previous.isSignedIn) {
      state = const AsyncLoading<AnimeWitcherAccountSnapshot>();
    }
    try {
      final value = await operation();
      state = AsyncData(value);
      if (bumpData) {
        ref.read(accountDataRevisionProvider.notifier).bump();
      }
    } catch (error, stackTrace) {
      state = previous.isSignedIn
          ? AsyncData(previous)
          : AsyncError(error, stackTrace);
      rethrow;
    }
  }
}
