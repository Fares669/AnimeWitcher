import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../domain/entity/multimedia_item.dart';
import '../storage/library_category.dart';
import '../storage/secure_token_storage.dart';
import '../storage/storage_service.dart';
import '../utils/episode_label.dart';
import 'animewitcher_account_config.dart';
import 'animewitcher_account_models.dart';
import 'animewitcher_comment_models.dart';
import 'animewitcher_sync_conflict.dart';
import 'animewitcher_sync_ids.dart';
import 'firebase_auth_rest_client.dart';
import 'firebase_functions_rest_client.dart';
import 'firebase_storage_rest_client.dart';
import 'firestore_rest_client.dart';

class AnimeWitcherAccountService {
  AnimeWitcherAccountService({
    required StorageService storage,
    required SecureTokenStorage secureStorage,
    FirebaseAuthRestClient? auth,
    FirestoreRestClient? firestore,
    FirebaseStorageRestClient? cloudStorage,
    FirebaseFunctionsRestClient? functions,
  }) : _storage = storage,
       _secureStorage = secureStorage,
       _auth = auth ?? FirebaseAuthRestClient(),
       _firestore = firestore ?? FirestoreRestClient(),
       _cloudStorage = cloudStorage ?? FirebaseStorageRestClient(),
       _functions = functions ?? FirebaseFunctionsRestClient();

  static const String _sessionKey = 'animewitcher_account_session_v1';
  static const String _profileKey = 'animewitcher_account_profile_v1';
  static const String _legacyLastSyncKey =
      'animewitcher_account_last_sync_v1';
  static const String _pendingWatchedKey =
      'animewitcher_account_pending_watched_v1';
  static const String _pendingLibraryDeletesKey =
      'animewitcher_account_pending_library_deletes_v1';
  static const String _pendingContinueDeletesKey =
      'animewitcher_account_pending_continue_deletes_v1';
  static const String _pendingLastWatchedDeletesKey =
      'animewitcher_account_pending_last_watched_deletes_v1';
  static const String animeWitcherProvider =
      'com.fares669.animewitcher.native';

  final StorageService _storage;
  final SecureTokenStorage _secureStorage;
  final FirebaseAuthRestClient _auth;
  final FirestoreRestClient _firestore;
  final FirebaseStorageRestClient _cloudStorage;
  final FirebaseFunctionsRestClient _functions;
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;

  AnimeWitcherSession? _session;
  AnimeWitcherProfile? _profile;
  DateTime? _lastSyncAt;
  bool _googleInitialized = false;
  int _sessionGeneration = 0;
  Future<AnimeWitcherSession>? _refreshInFlight;
  Future<void>? _syncInFlight;
  DateTime? _lastVerificationEmailSentAt;

  final Map<String, Set<String>> _watchedEpisodeCache =
      <String, Set<String>>{};
  final Set<String> _ownedProfileDocumentIds = <String>{};
  final Set<String> _allEpisodesWatchedAnime = <String>{};
  final Set<String> _loadedWatchedAnime = <String>{};
  final Map<String, int> _stopTimeCache = <String, int>{};
  final Map<String, Future<void>> _watchedWriteQueues =
      <String, Future<void>>{};
  final Map<String, Future<void>> _progressWriteQueues =
      <String, Future<void>>{};
  final Map<String, Future<void>> _libraryWriteQueues =
      <String, Future<void>>{};
  Future<void> _pendingStorageWrite = Future<void>.value();
  int _mutationSerial = 0;

  AnimeWitcherAccountSnapshot get snapshot => AnimeWitcherAccountSnapshot(
    profile: _profile,
    lastSyncAt: _lastSyncAt,
  );

  bool get isSignedIn => _session != null && _profile != null;
  String? get accountUid => _profile?.uid;

  /// Whether [comment] belongs to the active AnimeWitcher account.
  ///
  /// Some legacy AnimeWitcher accounts have duplicate `users` documents for
  /// the same Firebase UID. The official client warns about that condition,
  /// but comments keep the concrete user document ID that created them. Keep
  /// all verified aliases so those comments remain manageable.
  bool ownsComment(AnimeWitcherComment comment) {
    if (_session == null || _profile == null || comment.userId.isEmpty) {
      return false;
    }
    return comment.userId == _profile!.documentId ||
        _ownedProfileDocumentIds.contains(comment.userId);
  }

  Future<AnimeWitcherAccountSnapshot> restoreSession() async {
    final rawSession = await _secureStorage.read(_sessionKey);
    if (rawSession == null || rawSession.isEmpty) return snapshot;

    try {
      _session = AnimeWitcherSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(rawSession) as Map),
      );
      _sessionGeneration++;
      final rawProfile = await _secureStorage.read(_profileKey);
      if (rawProfile != null && rawProfile.isNotEmpty) {
        _profile = AnimeWitcherProfile.fromJson(
          Map<String, dynamic>.from(jsonDecode(rawProfile) as Map),
        );
      }
      final cachedProfile = _profile;
      _lastSyncAt = DateTime.tryParse(
        _storage.getString(
              cachedProfile == null
                  ? _legacyLastSyncKey
                  : _lastSyncKey(cachedProfile.uid),
            ) ??
            '',
      );

      final session = await _authorizedSession();
      final user = await _auth.lookup(session.idToken);
      if (session.signInMethod == AnimeWitcherSignInMethod.email &&
          user['emailVerified'] != true) {
        await _clearLocalSession();
        return snapshot;
      }
      _session = session.copyWith(
        email: _optionalString(user['email']),
        displayName: _optionalString(user['displayName']),
        photoUrl: _optionalString(user['photoUrl']),
        providerIds: _providerIdsFromUser(user['providerUserInfo']),
      );
      _profile = await _resolveProfile(
        _session!,
        createIfMissing:
            _session!.signInMethod == AnimeWitcherSignInMethod.google,
      );
      await _persistSession();
      _syncNewAuthEmailBestEffort(_session!);
      await syncAll();
    } on AnimeWitcherAccountException catch (error) {
      if (error.code == 'invalid-session' ||
          error.code == 'account-not-found' ||
          error.code == 'profile-not-found' ||
          error.code == 'account-banned') {
        await _clearLocalSession();
      } else if (kDebugMode) {
        debugPrint('[AnimeWitcherAccount] Restore deferred: $error');
      }
    } catch (error) {
      // Keep a valid cached account visible while offline. All local features
      // remain available and the next manual/automatic sync retries safely.
      if (kDebugMode) {
        debugPrint('[AnimeWitcherAccount] Offline restore: $error');
      }
    }
    return snapshot;
  }

  Future<AnimeWitcherAccountSnapshot> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final session = await _auth.signInWithEmail(
      email: email,
      password: password,
    );
    return _completeSignIn(session);
  }

  Future<AnimeWitcherAccountSnapshot> signInWithGoogle() async {
    await _initializeGoogleSignIn();
    final googleAccount = await _googleSignIn.authenticate();
    final googleToken = googleAccount.authentication.idToken;
    if (googleToken == null || googleToken.isEmpty) {
      throw const AnimeWitcherAccountException(
        'google-token-missing',
        'Google did not return a usable sign-in token.',
      );
    }
    final session = await _auth.signInWithGoogleIdToken(googleToken);
    return _completeSignIn(session);
  }

  Future<void> createEmailAccount({
    required String userName,
    required String email,
    required String password,
  }) async {
    final normalizedName = userName.trim();
    if (normalizedName.length < 5 || normalizedName.length > 25) {
      throw const AnimeWitcherAccountException(
        'invalid-user-name',
        'The user name must contain 5 to 25 characters.',
      );
    }
    if (!AnimeWitcherAccountConfig.isTrustedRegistrationEmail(email)) {
      throw const AnimeWitcherAccountException(
        'untrusted-email-domain',
        'Use a Gmail, Outlook, or Yahoo email address.',
      );
    }
    if (password.length < 6) {
      throw const AnimeWitcherAccountException(
        'weak-password',
        'The password must contain at least six characters.',
      );
    }
    final session = await _auth.createEmailAccount(
      email: email,
      password: password,
    );
    _session = session;
    _sessionGeneration++;
    try {
      try {
        await _resolveProfile(
          session,
          createIfMissing: true,
          requestedUserName: normalizedName,
        );
      } catch (_) {
        // AnimeWitcher removes the Firebase Auth user if its Firestore profile
        // cannot be created. Mirror that behavior so retrying registration does
        // not fail with an orphaned "email already in use" account.
        try {
          await _auth.deleteAccount(session.idToken);
        } catch (_) {}
        rethrow;
      }
      await _auth.sendEmailVerification(session.idToken);
    } finally {
      await _clearLocalSession();
    }
  }

  Future<void> resendEmailVerification({
    required String email,
    required String password,
  }) async {
    const cooldown = Duration(seconds: 60);
    final sentAt = _lastVerificationEmailSentAt;
    if (sentAt != null) {
      final elapsed = DateTime.now().difference(sentAt);
      if (elapsed < cooldown) {
        final secondsLeft =
            ((cooldown - elapsed).inMilliseconds / 1000).ceil();
        throw AnimeWitcherAccountException(
          'verification-cooldown',
          'Request a new verification email after $secondsLeft seconds.',
        );
      }
    }
    final session = await _auth.signInWithEmail(
      email: email,
      password: password,
      requireVerified: false,
    );
    await _auth.sendEmailVerification(session.idToken);
    _lastVerificationEmailSentAt = DateTime.now();
  }

  Future<void> sendPasswordResetEmail(String email) {
    return _auth.sendPasswordResetEmail(email);
  }

  Future<AnimeWitcherAccountSnapshot> updateProfile({
    required String userName,
    required String bio,
    required String country,
    required String birthYear,
    Uint8List? avatarBytes,
    Uint8List? coverBytes,
  }) async {
    final profile = _profile;
    if (profile == null || _session == null) {
      throw const AnimeWitcherAccountException(
        'not-signed-in',
        'Sign in before editing the account profile.',
      );
    }
    final normalizedName = userName.trim();
    final normalizedBio = bio.trim();
    final normalizedCountry = country.trim();
    final normalizedBirthYear = birthYear.trim();
    if (normalizedName.length < 5 || normalizedName.length > 25) {
      throw const AnimeWitcherAccountException(
        'invalid-user-name',
        'The user name must contain 5 to 25 characters.',
      );
    }
    if (normalizedBio.length > 200) {
      throw const AnimeWitcherAccountException(
        'bio-too-long',
        'The profile bio must contain no more than 200 characters.',
      );
    }
    if (normalizedCountry.length > 30) {
      throw const AnimeWitcherAccountException(
        'country-too-long',
        'The country must contain no more than 30 characters.',
      );
    }
    if (normalizedBirthYear.isNotEmpty) {
      final parsed = int.tryParse(normalizedBirthYear);
      if (parsed == null || parsed < 1970 || parsed > 2020) {
        throw const AnimeWitcherAccountException(
          'invalid-birth-year',
          'The birth year must be between 1970 and 2020.',
        );
      }
    }
    final existingBirthYear = profile.birthYear?.trim() ?? '';
    if (existingBirthYear.isNotEmpty &&
        normalizedBirthYear != existingBirthYear) {
      throw const AnimeWitcherAccountException(
        'birth-year-locked',
        'The birth year can only be set once.',
      );
    }
    const maximumImageBytes = 10 * 1024 * 1024;
    if ((avatarBytes?.length ?? 0) > maximumImageBytes ||
        (coverBytes?.length ?? 0) > maximumImageBytes) {
      throw const AnimeWitcherAccountException(
        'image-too-large',
        'The selected image is too large.',
      );
    }

    var avatarUrl = profile.photoUrl;
    var coverUrl = profile.coverUrl;
    final nameChanged = normalizedName != (profile.userName?.trim() ?? '');
    await _authenticated((token) async {
      if (avatarBytes != null) {
        avatarUrl = await _cloudStorage.uploadAccountImage(
          idToken: token,
          documentId: profile.documentId,
          kind: AnimeWitcherProfileImageKind.avatar,
          bytes: avatarBytes,
        );
      }
      if (coverBytes != null) {
        coverUrl = await _cloudStorage.uploadAccountImage(
          idToken: token,
          documentId: profile.documentId,
          kind: AnimeWitcherProfileImageKind.cover,
          bytes: coverBytes,
        );
      }

      final fields = <String, dynamic>{};
      final deleteFields = <String>{};
      if (nameChanged) fields['user_name'] = normalizedName;

      void setOptional(String field, String value, String existing) {
        if (value == existing) return;
        if (value.isEmpty) {
          if (existing.isNotEmpty) deleteFields.add(field);
        } else {
          fields[field] = value;
        }
      }

      setOptional('bio', normalizedBio, profile.bio?.trim() ?? '');
      setOptional('country', normalizedCountry, profile.country?.trim() ?? '');
      setOptional(
        'birth_date',
        normalizedBirthYear,
        profile.birthYear?.trim() ?? '',
      );
      if (avatarUrl != profile.photoUrl && avatarUrl != null) {
        fields['pic_uri'] = avatarUrl;
      }
      if (coverUrl != profile.coverUrl && coverUrl != null) {
        fields['cover_uri'] = coverUrl;
      }
      if (fields.isNotEmpty || deleteFields.isNotEmpty) {
        await _firestore.patchDocument(
          'users/${profile.documentId}',
          fields,
          token,
          deleteFields: deleteFields,
          // DocumentReference.update() in the official client never creates a
          // missing user document. Match that precondition on the REST API.
          requireExisting: true,
        );
      }
    });

    if (!_isCurrentProfile(profile)) {
      throw const AnimeWitcherAccountException(
        'session-changed',
        'The active account changed while updating the profile.',
      );
    }
    _profile = profile.copyWith(
      userName: normalizedName,
      photoUrl: avatarUrl,
      coverUrl: coverUrl,
      bio: normalizedBio.isEmpty ? null : normalizedBio,
      country: normalizedCountry.isEmpty ? null : normalizedCountry,
      birthYear: normalizedBirthYear.isEmpty ? null : normalizedBirthYear,
      clearBio: normalizedBio.isEmpty,
      clearCountry: normalizedCountry.isEmpty,
      clearBirthYear: normalizedBirthYear.isEmpty,
    );
    if (nameChanged) {
      _signalUserNameUpdateBestEffort(_profile!, normalizedName);
    }
    await _persistSession();
    return snapshot;
  }

  Future<AnimeWitcherAccountSnapshot> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final profile = _profile;
    final activeSession = _session;
    if (profile == null || activeSession == null) {
      throw const AnimeWitcherAccountException(
        'not-signed-in',
        'Sign in before changing the password.',
      );
    }
    if (newPassword.length < 6) {
      throw const AnimeWitcherAccountException(
        'weak-password',
        'The password must contain at least six characters.',
      );
    }

    final usesPassword = profile.hasPasswordProvider ||
        (profile.providerIds.isEmpty &&
            profile.signInMethod == AnimeWitcherSignInMethod.email);
    AnimeWitcherSession reauthenticated;
    if (usesPassword) {
      final email = profile.email ?? activeSession.email;
      if (email == null || currentPassword.length < 6) {
        throw const AnimeWitcherAccountException(
          'invalid-credentials',
          'Enter the current password.',
        );
      }
      reauthenticated = await _auth.signInWithEmail(
        email: email,
        password: currentPassword,
        requireVerified: false,
      );
    } else if (profile.hasGoogleProvider ||
        profile.signInMethod == AnimeWitcherSignInMethod.google) {
      reauthenticated = await _reauthenticateWithGoogle(profile);
    } else {
      throw const AnimeWitcherAccountException(
        'unsupported-sign-in-provider',
        'The current sign-in method cannot change the password.',
      );
    }
    _ensureSameAccount(profile, reauthenticated);
    reauthenticated = reauthenticated.copyWith(
      signInMethod: activeSession.signInMethod,
    );
    final AnimeWitcherSession updated;
    if (usesPassword) {
      updated = await _auth.updatePassword(
        previous: reauthenticated,
        newPassword: newPassword,
      );
    } else {
      final email = reauthenticated.email ?? profile.email;
      if (email == null || email.trim().isEmpty) {
        throw const AnimeWitcherAccountException(
          'account-email-missing',
          'The account email address could not be read.',
        );
      }
      updated = await _auth.linkEmailPassword(
        previous: reauthenticated,
        email: email,
        newPassword: newPassword,
      );
    }
    _session = updated.copyWith(signInMethod: activeSession.signInMethod);
    _profile = profile.copyWith(providerIds: _session!.providerIds);
    await _persistSession();
    return snapshot;
  }

  Future<AnimeWitcherAccountSnapshot> requestEmailChange({
    required String newEmail,
    required String currentPassword,
  }) async {
    final profile = _profile;
    final activeSession = _session;
    if (profile == null || activeSession == null) {
      throw const AnimeWitcherAccountException(
        'not-signed-in',
        'Sign in before changing the email address.',
      );
    }
    final normalizedEmail = newEmail.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(normalizedEmail)) {
      throw const AnimeWitcherAccountException(
        'invalid-email',
        'Enter a valid email address.',
      );
    }
    if (normalizedEmail.toLowerCase() ==
        (profile.email ?? activeSession.email ?? '').toLowerCase()) {
      throw const AnimeWitcherAccountException(
        'same-email',
        'This is already the current email address.',
      );
    }

    final usesPassword = profile.hasPasswordProvider ||
        (profile.providerIds.isEmpty &&
            profile.signInMethod == AnimeWitcherSignInMethod.email);
    AnimeWitcherSession reauthenticated;
    if (usesPassword) {
      final currentEmail = profile.email ?? activeSession.email;
      if (currentEmail == null || currentPassword.length < 6) {
        throw const AnimeWitcherAccountException(
          'invalid-credentials',
          'Enter the current password.',
        );
      }
      reauthenticated = await _auth.signInWithEmail(
        email: currentEmail,
        password: currentPassword,
        requireVerified: false,
      );
    } else if (profile.hasGoogleProvider ||
        profile.signInMethod == AnimeWitcherSignInMethod.google) {
      reauthenticated = await _reauthenticateWithGoogle(profile);
    } else {
      throw const AnimeWitcherAccountException(
        'unsupported-sign-in-provider',
        'The current sign-in method cannot change the email address.',
      );
    }
    _ensureSameAccount(profile, reauthenticated);
    await _auth.sendEmailChangeVerification(
      idToken: reauthenticated.idToken,
      newEmail: normalizedEmail,
    );
    await signOut();
    return snapshot;
  }

  Future<AnimeWitcherAccountSnapshot> deleteAccount() async {
    final profile = _profile;
    if (profile == null || _session == null) {
      throw const AnimeWitcherAccountException(
        'not-signed-in',
        'Sign in before deleting the account.',
      );
    }
    await _authenticated(
      (token) => _firestore.patchDocument(
        'users/${profile.documentId}',
        const <String, dynamic>{'delete_account': true},
        token,
      ),
    );
    await signOut();
    return snapshot;
  }

  Future<void> _initializeGoogleSignIn() async {
    if (!AnimeWitcherAccountConfig.googleConfigured) {
      throw const AnimeWitcherAccountException(
        'google-not-configured',
        'Google sign-in is not configured for this platform.',
      );
    }
    if (_googleInitialized) return;
    await _googleSignIn.initialize(
      clientId: AnimeWitcherAccountConfig.googleIosClientId.trim().isEmpty
          ? null
          : AnimeWitcherAccountConfig.googleIosClientId,
      serverClientId: AnimeWitcherAccountConfig.googleServerClientId,
    );
    _googleInitialized = true;
  }

  Future<AnimeWitcherSession> _reauthenticateWithGoogle(
    AnimeWitcherProfile profile,
  ) async {
    await _initializeGoogleSignIn();
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    final googleAccount = await _googleSignIn.authenticate();
    final googleToken = googleAccount.authentication.idToken;
    if (googleToken == null || googleToken.isEmpty) {
      throw const AnimeWitcherAccountException(
        'google-token-missing',
        'Google did not return a usable sign-in token.',
      );
    }
    final AnimeWitcherSession session;
    try {
      session = await _auth.reauthenticateWithGoogleIdToken(googleToken);
    } on AnimeWitcherAccountException catch (error) {
      if (error.code == 'invalid-session' || error.code == 'account-not-found') {
        throw const AnimeWitcherAccountException(
          'wrong-google-account',
          'Choose the same Google account to confirm your identity.',
        );
      }
      rethrow;
    }
    _ensureSameAccount(profile, session);
    return session;
  }

  void _ensureSameAccount(
    AnimeWitcherProfile profile,
    AnimeWitcherSession session,
  ) {
    if (session.uid != profile.uid) {
      throw const AnimeWitcherAccountException(
        'wrong-google-account',
        'Choose the same Google account to confirm your identity.',
      );
    }
  }

  void _syncNewAuthEmailBestEffort(AnimeWitcherSession session) {
    if (session.email == null || session.email!.trim().isEmpty) return;
    unawaited(() async {
      try {
        await _functions.syncNewAuthEmailToFirestore(session.idToken);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[AnimeWitcherAccount] Email sync deferred: $error');
        }
      }
    }());
  }

  void _signalUserNameUpdateBestEffort(
    AnimeWitcherProfile profile,
    String userName,
  ) {
    unawaited(() async {
      try {
        await _authenticated(
          (token) => _firestore.setDocumentWithServerTimestamps(
            'users/${profile.documentId}/settings/user_data_update',
            <String, dynamic>{'name': userName},
            token,
            serverTimestampFields: const <String>{'date'},
          ),
        );
      } catch (error) {
        // AnimeWitcher treats this document as a background propagation
        // signal. A failure must not turn an already successful profile write
        // into a visible save error.
        if (kDebugMode) {
          debugPrint(
            '[AnimeWitcherAccount] User-name propagation deferred: $error',
          );
        }
      }
    }());
  }

  Future<void> signOut() async {
    if (_googleInitialized) {
      try {
        await _googleSignIn.signOut();
      } catch (_) {}
    }
    await _clearLocalSession();
  }

  Future<AnimeWitcherAccountSnapshot> _completeSignIn(
    AnimeWitcherSession session,
  ) async {
    _session = session;
    _sessionGeneration++;
    try {
      _profile = await _resolveProfile(
        session,
        createIfMissing:
            session.signInMethod == AnimeWitcherSignInMethod.google,
      );
      await _persistSession();
      _syncNewAuthEmailBestEffort(session);
    } catch (_) {
      await _clearLocalSession();
      rethrow;
    }
    try {
      await syncAll();
    } catch (error) {
      // Authentication and profile loading have already succeeded. A
      // temporary sync failure must not log the user out; manual sync retries
      // it from the account screen and all writes stay local-first meanwhile.
      if (kDebugMode) {
        debugPrint('[AnimeWitcherAccount] Initial sync deferred: $error');
      }
    }
    return snapshot;
  }

  /// Resolves AnimeWitcher's numeric relation IDs with the same single public
  /// Firestore `whereIn("mal_id", ...)` request used by the official app.
  /// Catalog reads must not depend on account restoration or sign-in.
  Future<List<Map<String, dynamic>>> resolveAnimeByMalIds(
    Iterable<int> malIds,
  ) async {
    final ids = malIds
        .where((id) => id > 0)
        .toSet()
        .take(10)
        .toList(growable: false);
    if (ids.isEmpty) return const <Map<String, dynamic>>[];

    final documents = await _firestore.queryByStringValues(
      collectionId: 'anime_list',
      field: 'mal_id',
      values: ids.map((id) => '$id'),
    );
    return documents.map((document) {
      final hit = Map<String, dynamic>.from(document.fields);
      hit.putIfAbsent('objectID', () => document.id);
      hit.putIfAbsent('anime_id', () => document.id);
      hit.putIfAbsent('path', () => document.id);
      return hit;
    }).toList(growable: false);
  }

  Future<AnimeWitcherCommentPage> loadComments(
    AnimeWitcherCommentTarget target, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async {
    final documents = await _firestore.queryPublishedComments(
      target.collectionPath,
      orderField: sort.orderField,
      descending: sort.descending,
      startAfter: cursor,
      limit: limit,
    );
    final comments = documents
        .map(AnimeWitcherComment.fromDocument)
        .where((comment) => comment.text.isNotEmpty)
        .toList(growable: false);
    final hydrated = await _hydrateCommentLikes(comments);
    return AnimeWitcherCommentPage(
      items: hydrated,
      cursor: documents.isEmpty ? cursor : documents.last,
      hasMore: documents.length >= limit,
    );
  }

  Future<AnimeWitcherCommentPage> loadReplies(
    AnimeWitcherComment parent, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async {
    final documents = await _firestore.queryReplies(
      parent.repliesCollectionPath,
      orderField: sort.orderField,
      descending: sort.descending,
      startAfter: cursor,
      limit: limit,
    );
    final replies = documents
        .map(AnimeWitcherComment.fromDocument)
        .where((reply) => reply.text.isNotEmpty)
        .toList(growable: false);
    final hydrated = await _hydrateCommentLikes(replies);
    return AnimeWitcherCommentPage(
      items: hydrated,
      cursor: documents.isEmpty ? cursor : documents.last,
      hasMore: documents.length >= limit,
    );
  }

  Future<AnimeWitcherCommentPage> loadMyComments({
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async {
    final profile = _profile;
    if (profile == null || _session == null) {
      throw const AnimeWitcherAccountException(
        'not-signed-in',
        'Sign in to AnimeWitcher to manage your comments.',
      );
    }
    final documents = await _authenticated(
      (token) => _firestore.queryUserComments(
        userId: profile.documentId,
        idToken: token,
        orderField: sort.orderField,
        descending: sort.descending,
        startAfter: cursor,
        limit: limit,
      ),
    );
    final comments = documents
        .map(
          (document) => AnimeWitcherComment.fromDocument(
            document,
            fallbackUserName: profile.userName,
            fallbackUserPhotoUrl: profile.photoUrl,
          ),
        )
        .where((comment) => comment.text.isNotEmpty)
        .toList(growable: false);
    return AnimeWitcherCommentPage(
      items: comments,
      cursor: documents.isEmpty ? cursor : documents.last,
      hasMore: documents.length >= limit,
    );
  }

  Future<AnimeWitcherComment> updateOwnComment(
    AnimeWitcherComment comment,
    String rawText, {
    required bool spoiler,
  }) async {
    final text = rawText.trim();
    if (text.isEmpty) {
      throw const AnimeWitcherAccountException(
        'comment-empty',
        'Enter a comment before saving.',
      );
    }
    if (text.length > 500) {
      throw const AnimeWitcherAccountException(
        'comment-too-long',
        'Comments can contain at most 500 characters.',
      );
    }
    final profile = _ownedCommentProfile(comment);
    await _authenticated((token) async {
      final userDocument = await _firestore.getDocument(
        'users/${profile.documentId}',
        token,
      );
      if (userDocument?.fields['banned'] == true) {
        throw const AnimeWitcherAccountException(
          'comment-banned',
          'This account is blocked from commenting.',
        );
      }
      final registrationDate = _dateValue(
        userDocument?.fields['registration_date'],
      );
      if (registrationDate != null &&
          DateTime.now().toUtc().difference(registrationDate.toUtc()) <
              const Duration(days: 7)) {
        throw const AnimeWitcherAccountException(
          'comment-account-too-new',
          'The account must be at least seven days old before editing comments.',
        );
      }
      await _firestore.patchDocument(
        comment.path,
        <String, dynamic>{'comment': text, 'spoiler': spoiler},
        token,
        requireExisting: true,
      );
    });
    return comment.copyWith(text: text, spoiler: spoiler);
  }

  Future<void> deleteOwnComment(AnimeWitcherComment comment) async {
    _ownedCommentProfile(comment);
    await _authenticated(
      (token) => _firestore.deleteDocument(comment.path, token),
    );
  }

  Future<AnimeWitcherComment> closeOwnCommentReplies(
    AnimeWitcherComment comment,
  ) async {
    _ownedCommentProfile(comment);
    if (comment.repliesClosed) return comment;
    await _authenticated(
      (token) => _firestore.patchDocument(
        comment.path,
        const <String, dynamic>{'replies_closed': true},
        token,
        requireExisting: true,
      ),
    );
    return comment.copyWith(repliesClosed: true);
  }

  AnimeWitcherProfile _ownedCommentProfile(AnimeWitcherComment comment) {
    final profile = _profile;
    if (profile == null || _session == null) {
      throw const AnimeWitcherAccountException(
        'not-signed-in',
        'Sign in to AnimeWitcher to manage your comments.',
      );
    }
    final pathSegments = comment.path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (!ownsComment(comment) || !pathSegments.contains('comments')) {
      throw const AnimeWitcherAccountException(
        'permission-denied',
        'Only the comment author can modify this comment.',
      );
    }
    return comment.userId == profile.documentId
        ? profile
        : profile.copyWith(documentId: comment.userId);
  }

  Future<List<AnimeWitcherComment>> _hydrateCommentLikes(
    List<AnimeWitcherComment> comments,
  ) async {
    final profile = _profile;
    if (comments.isEmpty || profile == null || _session == null) return comments;
    return _authenticated((token) async {
      return Future.wait<AnimeWitcherComment>(
        comments.map((comment) async {
          if (ownsComment(comment)) return comment;
          try {
            final like = await _firestore.getDocument(
              '${comment.path}/likes/${profile.documentId}',
              token,
            );
            return comment.copyWith(likedByMe: like != null);
          } catch (_) {
            // Reading comments must never fail just because the optional
            // per-user like marker could not be fetched.
            return comment;
          }
        }),
      );
    });
  }

  Future<AnimeWitcherComment> toggleCommentLike(
    AnimeWitcherComment comment,
  ) async {
    final profile = _profile;
    if (profile == null || _session == null) {
      throw const AnimeWitcherAccountException(
        'not-signed-in',
        'Sign in to AnimeWitcher before liking comments.',
      );
    }
    // AnimeWitcher does not let a user like their own comment/reply.
    if (ownsComment(comment)) return comment;

    final likePath = '${comment.path}/likes/${profile.documentId}';
    await _authenticated((token) async {
      if (comment.likedByMe) {
        await _firestore.deleteDocument(likePath, token);
      } else {
        // The official client writes a document whose only field is a
        // Firestore server timestamp named `date`.
        await _firestore.setDocumentWithServerTimestamps(
          likePath,
          const <String, dynamic>{},
          token,
          serverTimestampFields: const <String>{'date'},
          merge: false,
        );
      }
    });

    return comment.copyWith(
      likedByMe: !comment.likedByMe,
      likes: comment.likedByMe
          ? (comment.likes - 1).clamp(0, 1 << 31).toInt()
          : comment.likes + 1,
    );
  }

  Future<void> publishReply(
    AnimeWitcherComment parent,
    String rawReply,
  ) async {
    final reply = rawReply.trim();
    if (reply.isEmpty) {
      throw const AnimeWitcherAccountException(
        'comment-empty',
        'Enter a reply before publishing.',
      );
    }
    if (reply.length > 500) {
      throw const AnimeWitcherAccountException(
        'comment-too-long',
        'Replies can contain at most 500 characters.',
      );
    }
    if (parent.repliesClosed) {
      throw const AnimeWitcherAccountException(
        'replies-closed',
        'Replies are disabled for this comment.',
      );
    }

    final profile = _profile;
    if (profile == null || _session == null) {
      throw const AnimeWitcherAccountException(
        'not-signed-in',
        'Sign in to AnimeWitcher before publishing replies.',
      );
    }

    await _authenticated((token) async {
      final userDocument = await _firestore.getDocument(
        'users/${profile.documentId}',
        token,
      );
      if (userDocument?.fields['banned'] == true) {
        throw const AnimeWitcherAccountException(
          'comment-banned',
          'This account is blocked from commenting.',
        );
      }
      final registrationDate = _dateValue(
        userDocument?.fields['registration_date'],
      );
      if (registrationDate != null &&
          DateTime.now().toUtc().difference(registrationDate.toUtc()) <
              const Duration(days: 7)) {
        throw const AnimeWitcherAccountException(
          'comment-account-too-new',
          'The account must be at least seven days old before replying.',
        );
      }
      final latestReply = await _firestore.latestReplyByUser(
        userId: profile.documentId,
        idToken: token,
      );
      final latestDate = _dateValue(latestReply?.fields['date']);
      if (latestDate != null) {
        final elapsed = DateTime.now().toUtc().difference(latestDate.toUtc());
        if (!elapsed.isNegative && elapsed < const Duration(minutes: 1)) {
          throw const AnimeWitcherAccountException(
            'comment-cooldown',
            'Wait a moment before publishing another reply.',
          );
        }
      }
      await _firestore.createDocument(
        parent.repliesCollectionPath,
        <String, dynamic>{
          'comment': reply,
          'likes': 0,
          'user_id': profile.documentId,
        },
        token,
      );
    });
  }

  Future<void> publishComment(
    AnimeWitcherCommentTarget target,
    String rawComment, {
    bool spoiler = false,
  }) async {
    final comment = rawComment.trim();
    if (comment.isEmpty) {
      throw const AnimeWitcherAccountException(
        'comment-empty',
        'Enter a comment before publishing.',
      );
    }
    if (comment.length > 500) {
      throw const AnimeWitcherAccountException(
        'comment-too-long',
        'Comments can contain at most 500 characters.',
      );
    }

    final profile = _profile;
    if (profile == null || _session == null) {
      throw const AnimeWitcherAccountException(
        'not-signed-in',
        'Sign in to AnimeWitcher before publishing comments.',
      );
    }

    await _authenticated((token) async {
      final sourceDocument = await _firestore.getDocument(
        target.sourceDocumentPath,
        token,
      );
      if (sourceDocument?.fields['comments_closed'] == true) {
        throw const AnimeWitcherAccountException(
          'comments-closed',
          'Comments are disabled for this item.',
        );
      }

      final userDocument = await _firestore.getDocument(
        'users/${profile.documentId}',
        token,
      );
      if (userDocument == null) {
        throw const AnimeWitcherAccountException(
          'profile-not-found',
          'The AnimeWitcher profile could not be found.',
        );
      }
      if (userDocument.fields['banned'] == true) {
        throw const AnimeWitcherAccountException(
          'comment-banned',
          'This account is blocked from commenting.',
        );
      }

      final registrationDate = _dateValue(
        userDocument.fields['registration_date'],
      );
      if (registrationDate != null &&
          DateTime.now().toUtc().difference(registrationDate.toUtc()) <
              const Duration(days: 7)) {
        throw const AnimeWitcherAccountException(
          'comment-account-too-new',
          'The account must be at least seven days old before commenting.',
        );
      }

      var commentsLimit = 1;
      final constants = await _firestore.getDocument('Settings/constants', token);
      final commentsSettingsRaw = constants?.fields['comments'];
      if (commentsSettingsRaw is Map) {
        final commentsSettings = commentsSettingsRaw.map<String, dynamic>(
          (key, value) => MapEntry(key.toString(), value),
        );
        if (commentsSettings.containsKey('limit')) {
          commentsLimit = _intValue(commentsSettings['limit']);
        }
      }
      if (commentsLimit <= 0) {
        throw const AnimeWitcherAccountException(
          'comment-limit',
          'Comments are not available for this item.',
        );
      }
      final ownComments = await _firestore.queryCommentsByUserInCollection(
        collectionPath: target.collectionPath,
        userId: profile.documentId,
        idToken: token,
        limit: commentsLimit,
      );
      if (ownComments.length >= commentsLimit) {
        throw const AnimeWitcherAccountException(
          'comment-limit',
          'You reached the maximum number of comments for this item.',
        );
      }

      final latestComment = await _firestore.latestCommentByUser(
        userId: profile.documentId,
        idToken: token,
      );
      final latestDate = _dateValue(latestComment?.fields['date']);
      if (latestDate != null) {
        final elapsed = DateTime.now().toUtc().difference(latestDate.toUtc());
        if (!elapsed.isNegative && elapsed < const Duration(minutes: 1)) {
          throw const AnimeWitcherAccountException(
            'comment-cooldown',
            'Wait a moment before publishing another comment.',
          );
        }
      }

      await _firestore.createDocument(
        target.collectionPath,
        <String, dynamic>{
          'comment': comment,
          'likes': 0,
          'replies': 0,
          'user_id': profile.documentId,
          ...target.publishFields,
          if (spoiler) 'spoiler': true,
        },
        token,
      );
    });
  }

  /// Refreshes the Recently Watched list from AnimeWitcher's cloud data.
  ///
  /// The official app keeps playback state in continue_watching/stop_times and
  /// records the latest anime visit separately in last_watched.  Continue
  /// watching remains the authoritative source for the episode and resume
  /// position; last_watched supplies the ordering/date for this screen.
  Future<void> syncRecentWatched() async {
    if (!isSignedIn) return;
    final profile = _profile!;
    await _pendingStorageWrite;
    await _flushPendingLastWatchedDeletes(profile);
    if (!_isCurrentProfile(profile)) return;

    // AnimeWitcher keeps last_watched as its own collection. It is the only
    // server source for Recently Watched; removing a continue_watching document
    // must never remove or reorder this history.
    final recentDocs = await _authenticated(
      (token) => _firestore.listDocuments(
        'users/${profile.documentId}/last_watched',
        token,
      ),
    );
    if (!_isCurrentProfile(profile)) return;
    recentDocs.sort((a, b) {
      final aDate = _dateValue(a.fields['date'])?.millisecondsSinceEpoch ?? 0;
      final bDate = _dateValue(b.fields['date'])?.millisecondsSinceEpoch ?? 0;
      return bDate.compareTo(aDate);
    });

    final localByAnime = <String, Map<String, dynamic>>{};
    for (final raw in _storage.getWatchHistory()) {
      final animeId = AnimeWitcherSyncIds.animeIdFromUrl(
        (raw['url'] ?? '').toString(),
      );
      if (animeId != null) localByAnime[animeId] = raw;
    }

    for (final recent in recentDocs) {
      if (!_isCurrentProfile(profile)) return;
      final animeId =
          _optionalString(recent.fields['anime_id']) ?? recent.id;
      if (animeId.isEmpty) continue;
      final watchedAt =
          _dateValue(recent.fields['date']) ?? DateTime.fromMillisecondsSinceEpoch(0);
      final timestamp = watchedAt.millisecondsSinceEpoch;
      final local = localByAnime[animeId];
      if (local != null) {
        final url = _optionalString(local['url']);
        if (url != null && timestamp > 0) {
          await _storage.updateHistoryItemTimestampAndPosition(
            url,
            _optionalString(local['lastEpisodeUrl']),
            timestamp,
            _intValue(local['position']),
          );
          await _storage.markHistoryItemSynced(
            url,
            accountUid: profile.uid,
            syncedAt: timestamp,
          );
        }
        continue;
      }

      final item = await _itemForAnimeId(animeId);
      if (item == null || !_isCurrentProfile(profile)) continue;
      await _storage.saveProgress(
        item,
        0,
        0,
        timestamp: timestamp > 0
            ? timestamp
            : DateTime.now().millisecondsSinceEpoch,
        syncedAccountUid: profile.uid,
        syncedAt: timestamp > 0
            ? timestamp
            : DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  Future<void> recordLastWatched({
    required MultimediaItem item,
  }) async {
    if (!isSignedIn) return;
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(item.url);
    final profile = _profile;
    if (animeId == null || profile == null) return;
    await _enqueueProgressWrite(animeId, () async {
      if (!_isCurrentProfile(profile)) return;
      await _authenticated(
        (token) => _firestore.setDocumentWithServerTimestamps(
          'users/${profile.documentId}/last_watched/$animeId',
          <String, dynamic>{'anime_id': animeId},
          token,
          serverTimestampFields: const <String>{'date'},
        ),
      );
      if (!_isCurrentProfile(profile)) return;
      await _storage.markHistoryItemSynced(
        item.url,
        accountUid: profile.uid,
        syncedAt: DateTime.now().millisecondsSinceEpoch,
      );
    });
  }

  Future<void> removeLastWatched(String mainUrl) async {
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(mainUrl);
    final profile = _profile;
    if (animeId == null || profile == null) return;
    final mutationId = _pendingMutationId(animeId);
    final revision = _nextMutationRevision();
    await _mutatePending(_pendingLastWatchedDeletesKey, (values) {
      values[mutationId] = <String, dynamic>{
        'anime_id': animeId,
        'owner_uid': profile.uid,
        'revision': revision,
      };
    });
    if (!isSignedIn) return;
    await _deleteLastWatchedRemote(animeId, profile);
    await _removePendingMutation(
      _pendingLastWatchedDeletesKey,
      mutationId,
      revision,
    );
  }

  Future<void> _deleteLastWatchedRemote(
    String animeId,
    AnimeWitcherProfile profile,
  ) {
    return _enqueueProgressWrite(animeId, () async {
      if (!_isCurrentProfile(profile)) return;
      await _authenticated(
        (token) => _firestore.deleteDocument(
          'users/${profile.documentId}/last_watched/$animeId',
          token,
        ),
      );
    });
  }

  Future<void> _flushPendingLastWatchedDeletes(
    AnimeWitcherProfile profile,
  ) async {
    final pending = _readPendingMutations(_pendingLastWatchedDeletesKey);
    for (final entry in pending.entries) {
      if (!_isCurrentProfile(profile)) return;
      final mutation = entry.value;
      if (!_mutationBelongsToProfile(mutation, profile)) continue;
      final animeId = _optionalString(mutation['anime_id']);
      final revision = _optionalString(mutation['revision']);
      if (animeId == null || revision == null) continue;
      await _deleteLastWatchedRemote(animeId, profile);
      await _removePendingMutation(
        _pendingLastWatchedDeletesKey,
        entry.key,
        revision,
      );
    }
  }

  Future<void> syncAll() {
    if (!isSignedIn) return Future<void>.value();
    final active = _syncInFlight;
    if (active != null) return active;
    final profile = _profile!;

    final operation = () async {
      await Future.wait<void>(<Future<void>>[
        _syncLibrary(),
        _syncWatchedEpisodes(),
        _syncContinueWatching(),
      ]);
      if (!_isCurrentProfile(profile)) return;
      _lastSyncAt = DateTime.now();
      await _storage.setString(
        _lastSyncKey(profile.uid),
        _lastSyncAt!.toUtc().toIso8601String(),
      );
    }();
    _syncInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_syncInFlight, operation)) _syncInFlight = null;
    });
  }

  Future<AnimeWitcherProfile> _resolveProfile(
    AnimeWitcherSession session, {
    required bool createIfMissing,
    String? requestedUserName,
  }) async {
    final matches = await _authenticated(
      (token) => _firestore.queryByStringField(
        collectionId: 'users',
        field: 'uid',
        value: session.uid,
        idToken: token,
        limit: 2,
      ),
    );
    _ownedProfileDocumentIds
      ..clear()
      ..addAll(matches.map((document) => document.id));

    FirestoreDocument document;
    if (matches.isNotEmpty) {
      document = await _selectActiveProfileDocument(session, matches);
    } else {
      if (!createIfMissing) {
        throw const AnimeWitcherAccountException(
          'profile-not-found',
          'The AnimeWitcher profile could not be found.',
        );
      }
      final fields = _newUserFields(
        session,
        requestedUserName: requestedUserName,
      );
      document = await _authenticated(
        (token) => _firestore.createDocumentWithServerTimestamps(
          'users',
          fields,
          token,
          documentId:
              session.signInMethod == AnimeWitcherSignInMethod.email
              ? session.uid
              : null,
          serverTimestampFields: const <String>{'registration_date'},
        ),
      );
      _ownedProfileDocumentIds.add(document.id);
    }
    if (matches.length > 1 && kDebugMode) {
      // The official client warns about this legacy condition. Continue with
      // the document that owns the account's active data instead of locking
      // the user out of profile and comment management.
      debugPrint(
        '[AnimeWitcherAccount] Multiple profiles found for ${session.uid}; '
        'using ${document.id}.',
      );
    }

    final fields = document.fields;
    if (fields['banned'] == true) {
      throw const AnimeWitcherAccountException(
        'account-banned',
        'This AnimeWitcher account has been suspended.',
      );
    }
    return AnimeWitcherProfile(
      documentId: document.id,
      uid: (fields['uid'] ?? session.uid).toString(),
      signInMethod: session.signInMethod,
      // Firebase Auth is authoritative after a verified email change. The
      // official client asynchronously copies it back to Firestore.
      email: session.email ?? _optionalString(fields['email']),
      userName:
          _optionalString(fields['user_name']) ??
          requestedUserName ??
          session.displayName ??
          _emailName(session.email),
      photoUrl: _optionalString(fields['pic_uri']) ?? session.photoUrl,
      coverUrl: _optionalString(fields['cover_uri']),
      bio: _optionalString(fields['bio']),
      country: _optionalString(fields['country']),
      birthYear: _optionalString(fields['birth_date']),
      providerIds: session.providerIds.isEmpty
          ? <String>[
              session.signInMethod == AnimeWitcherSignInMethod.google
                  ? 'google.com'
                  : 'password',
            ]
          : session.providerIds,
    );
  }

  Future<FirestoreDocument> _selectActiveProfileDocument(
    AnimeWitcherSession session,
    List<FirestoreDocument> matches,
  ) async {
    if (matches.length == 1) return matches.first;

    // A legacy duplicate can have the same Auth UID and email while only one
    // document owns the account's real comments. Prefer the document with the
    // latest activity; this also restores the same concrete ID that the
    // official client keeps in `user_doc_id` on an already signed-in device.
    final latestComments = await _authenticated(
      (token) => Future.wait<FirestoreDocument?>(
        matches.map((document) async {
          try {
            return await _firestore.latestCommentByUser(
              userId: document.id,
              idToken: token,
            );
          } catch (_) {
            return null;
          }
        }),
      ),
    );
    var activeIndex = -1;
    DateTime? activeDate;
    for (var index = 0; index < latestComments.length; index++) {
      final date = _dateValue(latestComments[index]?.fields['date']);
      if (date != null && (activeDate == null || date.isAfter(activeDate))) {
        activeIndex = index;
        activeDate = date;
      }
    }
    if (activeIndex >= 0) return matches[activeIndex];

    final cached = _profile;
    if (cached != null && cached.uid == session.uid) {
      for (final document in matches) {
        if (document.id == cached.documentId) return document;
      }
    }

    // With no social activity, the oldest profile is the best representation
    // of the pre-duplication account. Fall back to Firestore's first result if
    // legacy documents do not carry a registration timestamp.
    FirestoreDocument? oldest;
    DateTime? oldestDate;
    for (final document in matches) {
      final date = _dateValue(document.fields['registration_date']);
      if (date != null && (oldestDate == null || date.isBefore(oldestDate))) {
        oldest = document;
        oldestDate = date;
      }
    }
    return oldest ?? matches.first;
  }

  Map<String, dynamic> _newUserFields(
    AnimeWitcherSession session, {
    String? requestedUserName,
  }) {
    final userName = requestedUserName?.trim().isNotEmpty == true
        ? requestedUserName!.trim()
        : session.displayName ?? _emailName(session.email);
    return <String, dynamic>{
      'uid': session.uid,
      'email': session.email ?? '',
      'user_name': userName,
      'pic_uri': session.photoUrl ?? '',
      'sign_in_method': session.signInMethod == AnimeWitcherSignInMethod.google
          ? 'google.com'
          : 'password',
      'banned': false,
      'settings': <String, dynamic>{
        'show_ads': true,
        'all_episodes_notif': true,
        'new_episodes_notif': 'الكل',
        'save_watched_episodes': true,
        'hide_ecchi_anime': false,
        'show_reviews_to_users': true,
        'show_comments_to_users': true,
        'news_notif': true,
        'show_fav_to_users': true,
        'comments_notif': true,
        'reviews_notif': true,
      },
      'statistics': <String, dynamic>{
        'episodes_views': 0,
        'movies_views': 0,
        'total_time': 0,
        'reviews': 0,
        'comments': 0,
        'not_seen_notif': 0,
      },
      'statistics_user_anime': <String, dynamic>{
        'completed': 0,
        'noWatching': 0,
        'onHold': 0,
        'pin': 0,
        'watching': 0,
        'ztotal': 0,
      },
      'statistics_user_manga': <String, dynamic>{
        'completed': 0,
        'noWatching': 0,
        'onHold': 0,
        'pin': 0,
        'watching': 0,
        'ztotal': 0,
      },
    };
  }

  Future<AnimeWitcherSession> _authorizedSession() async {
    final current = _session;
    final generation = _sessionGeneration;
    if (current == null) {
      throw const AnimeWitcherAccountException(
        'not-signed-in',
        'Sign in to synchronize AnimeWitcher data.',
      );
    }
    if (!current.needsRefresh) return current;
    return _refreshSession(current, generation);
  }

  Future<AnimeWitcherSession> _refreshSession(
    AnimeWitcherSession current,
    int generation, {
    bool force = false,
  }) async {
    if (!force && !current.needsRefresh) return current;
    final active = _refreshInFlight;
    if (active != null) return active;
    final operation = _auth.refresh(current);
    _refreshInFlight = operation;
    try {
      final refreshed = await operation;
      if (!_isCurrentSession(current, generation)) {
        throw const AnimeWitcherAccountException(
          'session-changed',
          'The active account changed while synchronizing.',
        );
      }
      _session = refreshed;
      await _persistSession();
      return refreshed;
    } finally {
      if (identical(_refreshInFlight, operation)) _refreshInFlight = null;
    }
  }

  Future<T> _authenticated<T>(
    Future<T> Function(String idToken) operation,
  ) async {
    var session = await _authorizedSession();
    final generation = _sessionGeneration;
    if (!_isCurrentSession(session, generation)) {
      throw const AnimeWitcherAccountException(
        'session-changed',
        'The active account changed while synchronizing.',
      );
    }
    try {
      return await operation(session.idToken);
    } on AnimeWitcherAccountException catch (error) {
      if (error.code != 'invalid-session') rethrow;
      final refreshed = await _refreshSession(
        session,
        generation,
        force: true,
      );
      if (!_isCurrentSession(session, generation)) {
        throw const AnimeWitcherAccountException(
          'session-changed',
          'The active account changed while synchronizing.',
        );
      }
      session = refreshed;
      return operation(refreshed.idToken);
    }
  }

  Future<void> _persistSession() async {
    final session = _session;
    if (session != null) {
      await _secureStorage.write(_sessionKey, jsonEncode(session.toJson()));
    }
    final profile = _profile;
    if (profile != null) {
      await _secureStorage.write(_profileKey, jsonEncode(profile.toJson()));
    }
  }

  Future<void> _clearLocalSession() async {
    _sessionGeneration++;
    _session = null;
    _profile = null;
    _ownedProfileDocumentIds.clear();
    _lastSyncAt = null;
    _refreshInFlight = null;
    _syncInFlight = null;
    _watchedEpisodeCache.clear();
    _allEpisodesWatchedAnime.clear();
    _loadedWatchedAnime.clear();
    _stopTimeCache.clear();
    _watchedWriteQueues.clear();
    _progressWriteQueues.clear();
    _libraryWriteQueues.clear();
    try {
      await _auth.signOut();
    } catch (_) {}
    await _secureStorage.delete(_sessionKey);
    await _secureStorage.delete(_profileKey);
    await _storage.remove(_legacyLastSyncKey);
  }

  Map<String, Map<String, dynamic>> _readPendingMutations(String storageKey) {
    final raw = _storage.getString(storageKey);
    if (raw == null || raw.isEmpty) {
      return <String, Map<String, dynamic>>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, Map<String, dynamic>>{};
      final output = <String, Map<String, dynamic>>{};
      decoded.forEach((dynamic key, dynamic value) {
        if (value is Map) {
          output[key.toString()] = Map<String, dynamic>.from(value);
        }
      });
      return output;
    } catch (_) {
      return <String, Map<String, dynamic>>{};
    }
  }

  Future<void> _mutatePending(
    String storageKey,
    void Function(Map<String, Map<String, dynamic>> values) mutation,
  ) {
    Future<void> run() async {
      final values = _readPendingMutations(storageKey);
      mutation(values);
      if (values.isEmpty) {
        await _storage.remove(storageKey);
      } else {
        await _storage.setString(storageKey, jsonEncode(values));
      }
    }

    final operation = _pendingStorageWrite.then<void>(
      (_) => run(),
      onError: (Object _, StackTrace __) => run(),
    );
    _pendingStorageWrite = operation.catchError((Object _) {});
    return operation;
  }

  String _nextMutationRevision() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_mutationSerial++}';

  String _pendingMutationId(String animeId, [String? episodeId]) {
    final anime = Uri.encodeComponent(animeId);
    if (episodeId == null) return anime;
    return '$anime|${Uri.encodeComponent(episodeId)}';
  }

  bool _mutationBelongsToProfile(
    Map<String, dynamic> mutation,
    AnimeWitcherProfile profile,
  ) {
    final owner = _optionalString(mutation['owner_uid']);
    return owner == null || owner == profile.uid;
  }

  Future<void> _removePendingMutation(
    String storageKey,
    String id,
    String revision,
  ) {
    return _mutatePending(storageKey, (values) {
      if (_optionalString(values[id]?['revision']) == revision) {
        values.remove(id);
      }
    });
  }

  // -------------------------------------------------------------------------
  // Anime lists
  // -------------------------------------------------------------------------

  Future<void> _syncLibrary() async {
    final profile = _profile!;
    await _pendingStorageWrite;
    await _flushPendingLibraryDeletes(profile);
    if (!_isCurrentProfile(profile)) return;
    final favoriteDocs = await _authenticated(
      (token) => _firestore.queryOrderedDocuments(
        'users/${profile.documentId}/fav_anime',
        token,
      ),
    );
    final listDocs = await _authenticated(
      (token) => _firestore.queryOrderedDocuments(
        'users/${profile.documentId}/user_anime',
        token,
      ),
    );
    if (!_isCurrentProfile(profile)) return;

    final remoteEntries = <String, _RemoteLibraryEntry>{};
    for (final document in listDocs) {
      final animeId = _animeIdFromListDocument(document);
      if (animeId == null) continue;
      remoteEntries[animeId] = _RemoteLibraryEntry(
        category: _categoryFromCloudType(document.fields['type']),
        favorite: false,
        document: document,
        updatedAt: _dateValue(document.fields['date']),
      );
    }
    for (final document in favoriteDocs) {
      final animeId = _animeIdFromFavorite(document);
      if (animeId == null) continue;
      final existing = remoteEntries[animeId];
      final favoriteUpdatedAt = _dateValue(document.fields['date']);
      remoteEntries[animeId] = _RemoteLibraryEntry(
        category: existing?.category,
        favorite: true,
        document: existing?.document ?? document,
        updatedAt: _latestDate(existing?.updatedAt, favoriteUpdatedAt),
      );
    }

    final localItems = _storage.getLibraryItems();
    final localByAnimeId = <String, MultimediaItem>{};
    for (final item in localItems) {
      final animeId = AnimeWitcherSyncIds.animeIdFromUrl(item.url);
      if (animeId != null) localByAnimeId[animeId] = item;
    }

    for (final entry in remoteEntries.entries) {
      if (!_isCurrentProfile(profile)) return;
      final url = AnimeWitcherSyncIds.mainUrl(entry.key);
      final remote = entry.value;
      final remoteMillis =
          remote.updatedAt?.millisecondsSinceEpoch ??
          DateTime.now().millisecondsSinceEpoch;
      final local = localByAnimeId[entry.key];
      if (local == null) {
        final item =
            _itemFromCompact(remote.document.fields['animewitcher_item']) ??
            await _itemForAnimeId(entry.key);
        if (item != null && _isCurrentProfile(profile)) {
          await _storage.addToLibrary(
            item,
            category: remote.category?.storageKey,
            replaceCategory: true,
            favorite: remote.favorite,
            updatedAt: remoteMillis,
            syncedAccountUid: profile.uid,
            syncedAt: remoteMillis,
          );
        }
        continue;
      }

      final localUpdatedAt = _storage.getLibraryItemUpdatedAt(url);
      final remoteUpdatedAt = remote.updatedAt?.millisecondsSinceEpoch ?? 0;
      final resolution = resolveAnimeWitcherSyncConflict(
        remoteExists: true,
        localUpdatedAt: localUpdatedAt,
        remoteUpdatedAt: remoteUpdatedAt,
        syncedAccountUid: _storage.getLibraryItemSyncedAccountUid(url),
        localSyncedAt: _storage.getLibraryItemSyncedAt(url),
        currentAccountUid: profile.uid,
      );
      if (resolution == AnimeWitcherSyncResolution.uploadLocal) {
        await saveLibraryItem(
          local,
          _localLibraryCategory(local.url),
          favorite: _storage.isLibraryItemFavorite(local.url),
          knownFavorites: favoriteDocs,
        );
        continue;
      }

      final remoteItem =
          _itemFromCompact(remote.document.fields['animewitcher_item']) ?? local;
      await _storage.addToLibrary(
        remoteItem,
        category: remote.category?.storageKey,
        replaceCategory: true,
        favorite: remote.favorite,
        updatedAt: remoteMillis,
        syncedAccountUid: profile.uid,
        syncedAt: remoteMillis,
      );
    }

    for (final item in localItems) {
      if (!_isCurrentProfile(profile)) return;
      final animeId = AnimeWitcherSyncIds.animeIdFromUrl(item.url);
      if (animeId == null || remoteEntries.containsKey(animeId)) continue;
      final syncedUid = _storage.getLibraryItemSyncedAccountUid(item.url);
      final syncedAt = _storage.getLibraryItemSyncedAt(item.url);
      final updatedAt = _storage.getLibraryItemUpdatedAt(item.url);
      final resolution = resolveAnimeWitcherSyncConflict(
        remoteExists: false,
        localUpdatedAt: updatedAt,
        remoteUpdatedAt: 0,
        syncedAccountUid: syncedUid,
        localSyncedAt: syncedAt,
        currentAccountUid: profile.uid,
      );
      if (resolution == AnimeWitcherSyncResolution.deleteLocal) {
        await _storage.removeFromLibrary(item.url);
        continue;
      }
      await saveLibraryItem(
        item,
        _localLibraryCategory(item.url),
        favorite: _storage.isLibraryItemFavorite(item.url),
        knownFavorites: favoriteDocs,
      );
    }
  }

  LibraryCategory? _localLibraryCategory(String url) {
    final raw = _storage.getLibraryItemCategory(url);
    if (raw == null) return null;
    final category = LibraryCategory.fromStorageKey(raw);
    return category.isPrimary ? category : null;
  }

  Future<void> saveLibraryItem(
    MultimediaItem item,
    LibraryCategory? category, {
    bool? favorite,
    List<FirestoreDocument>? knownFavorites,
  }) async {
    if (!isSignedIn) return;
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(item.url);
    final profile = _profile;
    if (animeId == null || profile == null) return;
    final primaryCategory = category == LibraryCategory.favorite ? null : category;
    final isFavorite = favorite ?? category == LibraryCategory.favorite;
    await _enqueueLibraryWrite(
      animeId,
      () => _saveLibraryItemInternal(
        item,
        primaryCategory,
        favorite: isFavorite,
        profile: profile,
        knownFavorites: knownFavorites,
      ),
    );
  }

  Future<void> _saveLibraryItemInternal(
    MultimediaItem item,
    LibraryCategory? category, {
    required bool favorite,
    required AnimeWitcherProfile profile,
    List<FirestoreDocument>? knownFavorites,
  }) async {
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(item.url);
    if (animeId == null || !_isCurrentProfile(profile)) return;
    final root = 'users/${profile.documentId}';
    final compact = _compactItem(item);

    if (category == null) {
      await _authenticated(
        (token) => _firestore.deleteDocument(
          '$root/user_anime/$animeId',
          token,
        ),
      );
    } else {
      await _authenticated(
        (token) => _firestore.setDocumentWithServerTimestamps(
          '$root/user_anime/$animeId',
          <String, dynamic>{
            'doc_ref': 'anime_list/$animeId',
            'type': _cloudType(category),
            'views': 0,
            'animewitcher_item': compact,
          },
          token,
          serverTimestampFields: const <String>{'date'},
        ),
      );
    }

    if (favorite) {
      await _authenticated(
        (token) => _firestore.setDocumentWithServerTimestamps(
          '$root/fav_anime/$animeId',
          <String, dynamic>{
            'anime_doc_id': 'anime_list/$animeId',
            'views': 0,
            'animewitcher_item': compact,
          },
          token,
          serverTimestampFields: const <String>{'date'},
        ),
      );
      final List<FirestoreDocument> legacyFavorites = knownFavorites ??
          await _authenticated<List<FirestoreDocument>>(
            (token) => _firestore.listDocuments(
              '$root/fav_anime',
              token,
            ),
          );
      for (final document in legacyFavorites) {
        if (document.id == animeId ||
            _animeIdFromFavorite(document) != animeId) {
          continue;
        }
        await _authenticated(
          (token) => _firestore.deleteDocument(document.path, token),
        );
      }
    } else {
      await _removeFavoriteEntries(
        animeId,
        profile: profile,
        known: knownFavorites,
      );
    }

    await _storage.markLibraryItemSynced(
      item.url,
      accountUid: profile.uid,
      syncedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> removeLibraryItem(String itemUrl) async {
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(itemUrl);
    final profile = _profile;
    if (animeId == null || profile == null) return;
    final mutationId = _pendingMutationId(animeId);
    final revision = _nextMutationRevision();
    await _mutatePending(_pendingLibraryDeletesKey, (values) {
      values[mutationId] = <String, dynamic>{
        'anime_id': animeId,
        'owner_uid': profile.uid,
        'revision': revision,
      };
    });
    if (!isSignedIn) return;
    await _deleteLibraryRemote(animeId, profile);
    await _removePendingMutation(
      _pendingLibraryDeletesKey,
      mutationId,
      revision,
    );
  }

  Future<void> _deleteLibraryRemote(
    String animeId,
    AnimeWitcherProfile profile,
  ) {
    return _enqueueLibraryWrite(animeId, () async {
      if (!_isCurrentProfile(profile)) return;
      await _authenticated(
        (token) => _firestore.deleteDocument(
          'users/${profile.documentId}/user_anime/$animeId',
          token,
        ),
      );
      await _removeFavoriteEntries(animeId, profile: profile);
    });
  }

  Future<void> _flushPendingLibraryDeletes(
    AnimeWitcherProfile profile,
  ) async {
    final pending = _readPendingMutations(_pendingLibraryDeletesKey);
    for (final entry in pending.entries) {
      if (!_isCurrentProfile(profile)) return;
      final mutation = entry.value;
      if (!_mutationBelongsToProfile(mutation, profile)) continue;
      final animeId = _optionalString(mutation['anime_id']);
      final revision = _optionalString(mutation['revision']);
      if (animeId == null || revision == null) continue;
      await _deleteLibraryRemote(animeId, profile);
      await _removePendingMutation(
        _pendingLibraryDeletesKey,
        entry.key,
        revision,
      );
    }
  }

  Future<void> _enqueueLibraryWrite(
    String animeId,
    Future<void> Function() write,
  ) {
    final previous = _libraryWriteQueues[animeId] ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous.then<void>(
      (_) => write(),
      onError: (Object _, StackTrace __) => write(),
    );
    _libraryWriteQueues[animeId] = operation;
    return operation.whenComplete(() {
      if (identical(_libraryWriteQueues[animeId], operation)) {
        _libraryWriteQueues.remove(animeId);
      }
    });
  }

  Future<void> _removeFavoriteEntries(
    String animeId, {
    required AnimeWitcherProfile profile,
    List<FirestoreDocument>? known,
  }) async {
    if (!_isCurrentProfile(profile)) return;
    final List<FirestoreDocument> docs = known ??
        await _authenticated<List<FirestoreDocument>>(
          (token) => _firestore.listDocuments(
            'users/${profile.documentId}/fav_anime',
            token,
          ),
        );
    for (final document in docs) {
      if (!_isCurrentProfile(profile)) return;
      if (_animeIdFromFavorite(document) != animeId) continue;
      await _authenticated(
        (token) => _firestore.deleteDocument(document.path, token),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Watched episodes and resume positions
  // -------------------------------------------------------------------------

  Future<void> _syncWatchedEpisodes() async {
    final profile = _profile!;
    await _primeWatchedEpisodeCache();
    if (!_isCurrentProfile(profile)) return;
    await _pendingStorageWrite;
    await _flushPendingWatched(profile);
  }

  Future<void> _primeWatchedEpisodeCache() async {
    final profile = _profile!;
    final docs = await _authenticated(
      (token) => _firestore.listDocuments(
        'users/${profile.documentId}/episodes_watched',
        token,
      ),
    );
    if (!_isCurrentProfile(profile)) return;
    _watchedEpisodeCache.clear();
    _allEpisodesWatchedAnime.clear();
    _loadedWatchedAnime.clear();
    for (final document in docs) {
      final values = document.fields['episodes_watched'];
      _watchedEpisodeCache[document.id] = values is List
          ? values.map((value) => value.toString()).toSet()
          : <String>{};
      if (document.fields['all_eps_watched'] == true) {
        _allEpisodesWatchedAnime.add(document.id);
      }
      _loadedWatchedAnime.add(document.id);
    }
  }

  Future<Set<String>> watchedEpisodeIds(
    String mainUrl, {
    bool refresh = false,
  }) async {
    if (!isSignedIn) return const <String>{};
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(mainUrl);
    if (animeId == null) return const <String>{};
    if (refresh || !_loadedWatchedAnime.contains(animeId)) {
      final profile = _profile!;
      final document = await _authenticated(
        (token) => _firestore.getDocument(
          'users/${profile.documentId}/episodes_watched/$animeId',
          token,
        ),
      );
      if (!_isCurrentProfile(profile)) return const <String>{};
      final raw = document?.fields['episodes_watched'];
      _watchedEpisodeCache[animeId] = raw is List
          ? raw.map((value) => value.toString()).toSet()
          : <String>{};
      if (document?.fields['all_eps_watched'] == true) {
        _allEpisodesWatchedAnime.add(animeId);
      } else {
        _allEpisodesWatchedAnime.remove(animeId);
      }
      _loadedWatchedAnime.add(animeId);
    }
    return Set<String>.unmodifiable(
      _watchedEpisodeCache[animeId] ?? const <String>{},
    );
  }

  bool isEpisodeWatchedCached(String mainUrl, String episodeUrl) {
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(mainUrl);
    final episodeId = AnimeWitcherSyncIds.episodeIdFromUrl(episodeUrl);
    if (animeId == null || episodeId == null) return false;
    return _allEpisodesWatchedAnime.contains(animeId) ||
        _watchedEpisodeCache[animeId]?.contains(episodeId) == true;
  }

  bool hasPendingEpisodeWatched(String mainUrl, String episodeUrl) {
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(mainUrl);
    final episodeId = AnimeWitcherSyncIds.episodeIdFromUrl(episodeUrl);
    if (animeId == null || episodeId == null) return false;
    final mutation = _readPendingMutations(
      _pendingWatchedKey,
    )[_pendingMutationId(animeId, episodeId)];
    if (mutation == null) return false;
    final owner = _optionalString(mutation['owner_uid']);
    final currentUid = _profile?.uid;
    return owner == null || (currentUid != null && owner == currentUid);
  }

  Future<void> setEpisodeWatched({
    required String mainUrl,
    required String episodeUrl,
    required bool watched,
    String animeType = 'anime',
  }) async {
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(mainUrl);
    final episodeId = AnimeWitcherSyncIds.episodeIdFromUrl(episodeUrl);
    final profile = _profile;
    if (animeId == null || episodeId == null) return;
    final mutationId = _pendingMutationId(animeId, episodeId);
    final revision = _nextMutationRevision();
    await _mutatePending(_pendingWatchedKey, (values) {
      values[mutationId] = <String, dynamic>{
        'anime_id': animeId,
        'episode_id': episodeId,
        'main_url': mainUrl,
        'episode_url': episodeUrl,
        'watched': watched,
        'anime_type': animeType,
        'owner_uid': profile?.uid,
        'revision': revision,
      };
    });
    if (profile == null || !isSignedIn) return;

    await _enqueueWatchedWrite(
      animeId,
      () => _setEpisodeWatchedInternal(
        mainUrl: mainUrl,
        animeId: animeId,
        episodeId: episodeId,
        profile: profile,
        watched: watched,
        animeType: animeType,
      ),
    );
    await _removePendingMutation(_pendingWatchedKey, mutationId, revision);
  }

  Future<void> _enqueueWatchedWrite(
    String animeId,
    Future<void> Function() write,
  ) {
    final previous = _watchedWriteQueues[animeId] ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous.then<void>(
      (_) => write(),
      onError: (Object _, StackTrace __) => write(),
    );
    _watchedWriteQueues[animeId] = operation;
    return operation.whenComplete(() {
      if (identical(_watchedWriteQueues[animeId], operation)) {
        _watchedWriteQueues.remove(animeId);
      }
    });
  }

  Future<void> _flushPendingWatched(AnimeWitcherProfile profile) async {
    final pending = _readPendingMutations(_pendingWatchedKey);
    for (final entry in pending.entries) {
      if (!_isCurrentProfile(profile)) return;
      final mutation = entry.value;
      if (!_mutationBelongsToProfile(mutation, profile)) continue;
      final animeId = _optionalString(mutation['anime_id']);
      final episodeId = _optionalString(mutation['episode_id']);
      final revision = _optionalString(mutation['revision']);
      if (animeId == null || episodeId == null || revision == null) continue;
      final mainUrl =
          _optionalString(mutation['main_url']) ??
          AnimeWitcherSyncIds.mainUrl(animeId);
      await _enqueueWatchedWrite(
        animeId,
        () => _setEpisodeWatchedInternal(
          mainUrl: mainUrl,
          animeId: animeId,
          episodeId: episodeId,
          profile: profile,
          watched: mutation['watched'] == true,
          animeType: _optionalString(mutation['anime_type']) ?? 'anime',
        ),
      );
      await _removePendingMutation(_pendingWatchedKey, entry.key, revision);
    }
  }

  Future<void> _setEpisodeWatchedInternal({
    required String mainUrl,
    required String animeId,
    required String episodeId,
    required AnimeWitcherProfile profile,
    required bool watched,
    required String animeType,
  }) async {
    if (!_isCurrentProfile(profile)) return;
    final values = Set<String>.from(await watchedEpisodeIds(mainUrl));
    if (watched) {
      values.add(episodeId);
      await _authenticated(
        (token) => _firestore.transformArrayField(
          'users/${profile.documentId}/episodes_watched/$animeId',
          idToken: token,
          field: 'episodes_watched',
          value: episodeId,
          append: true,
          baseFields: <String, dynamic>{
            'user_id': profile.documentId,
            'type': animeType,
            'last_episode_watched_id': episodeId,
          },
        ),
      );
    } else {
      values.remove(episodeId);
      // AnimeWitcher v1.4.6 removes a single watched episode with only
      // FieldValue.arrayRemove(episodeId). Do the REST equivalent here: no
      // extra field updates are bundled into the unwatch write.
      await _authenticated(
        (token) => _firestore.transformArrayField(
          'users/${profile.documentId}/episodes_watched/$animeId',
          idToken: token,
          field: 'episodes_watched',
          value: episodeId,
          append: false,
        ),
      );
    }
    if (!_isCurrentProfile(profile)) return;
    if (!watched) {
      // Confirm the server mutation before dropping the pending operation.
      final remoteValues = await watchedEpisodeIds(mainUrl, refresh: true);
      if (!_isCurrentProfile(profile)) return;
      _watchedEpisodeCache[animeId] = Set<String>.from(remoteValues);
      _allEpisodesWatchedAnime.remove(animeId);
    } else {
      _watchedEpisodeCache[animeId] = values;
    }
    _loadedWatchedAnime.add(animeId);
  }

  Future<int> remoteEpisodePosition({
    required String mainUrl,
    required String episodeUrl,
    bool refresh = false,
  }) async {
    if (!isSignedIn) return 0;
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(mainUrl);
    final episodeId = AnimeWitcherSyncIds.episodeIdFromUrl(episodeUrl);
    final profile = _profile;
    if (animeId == null || episodeId == null || profile == null) return 0;
    final cacheKey = '$animeId|$episodeId';
    final cached = _stopTimeCache[cacheKey];
    if (!refresh && cached != null) return cached;
    final document = await _authenticated(
      (token) => _firestore.getDocument(
        'users/${profile.documentId}/episodes_watched/$animeId/'
        'stop_times/$episodeId',
        token,
      ),
    );
    if (!_isCurrentProfile(profile)) return 0;
    final position = _intValue(document?.fields['stop_time']);
    _stopTimeCache[cacheKey] = position;
    return position;
  }

  /// Synchronizes only the continue-watching document for [mainUrl].
  ///
  /// The full account sync runs on sign-in and from the account screen, but a
  /// player can be opened much later while another device has already changed
  /// the resume point. Refreshing this single document before playback keeps
  /// resume state current without downloading every list and watched document.
  /// An unsynchronized local edit still wins and is retried through the normal
  /// progress queue.
  Future<void> syncContinueWatchingItem(String mainUrl) async {
    if (!isSignedIn) return;
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(mainUrl);
    final profile = _profile;
    if (animeId == null || profile == null) return;

    final pendingWrite = _progressWriteQueues[animeId];
    if (pendingWrite != null) {
      try {
        await pendingWrite;
      } catch (_) {}
    }
    await _pendingStorageWrite;
    await _flushPendingContinueDeletes(profile);
    if (!_isCurrentProfile(profile)) return;

    final remote = await _authenticated(
      (token) => _firestore.getDocument(
        'users/${profile.documentId}/continue_watching/$animeId',
        token,
      ),
    );
    if (!_isCurrentProfile(profile)) return;

    Map<String, dynamic>? local;
    for (final raw in _storage.getContinueWatching()) {
      final localAnimeId = AnimeWitcherSyncIds.animeIdFromUrl(
        (raw['url'] ?? '').toString(),
      );
      if (localAnimeId == animeId) {
        local = raw;
        break;
      }
    }

    final resolution = resolveAnimeWitcherSyncConflict(
      remoteExists: remote != null,
      localUpdatedAt: local == null ? 0 : _intValue(local['timestamp']),
      remoteUpdatedAt:
          _dateValue(remote?.fields['date_updated'])?.millisecondsSinceEpoch ?? 0,
      syncedAccountUid: _optionalString(local?['animeWitcherSyncedUid']),
      localSyncedAt: _intValue(local?['animeWitcherSyncedAt']),
      currentAccountUid: profile.uid,
    );

    if (resolution == AnimeWitcherSyncResolution.uploadLocal &&
        _hasMeaningfulPlayback(local)) {
      if (local != null) await _uploadContinueWatchingEntry(local, profile);
      return;
    }
    if (resolution == AnimeWitcherSyncResolution.deleteLocal) {
      if (local != null) {
        final localUrl = _optionalString(local['url']);
        if (localUrl != null) {
          await _storage.removeFromContinueWatching(localUrl);
        }
      }
      return;
    }
    if (remote != null) {
      await _importRemoteContinueWatchingEntry(
        animeId: animeId,
        fields: remote.fields,
        profile: profile,
        remoteDate: _dateValue(remote.fields['date_updated']),
      );
    }
  }

  Future<void> syncContinueWatching() async {
    if (!isSignedIn) return;
    await _syncContinueWatching();
  }

  Future<void> saveProgress({
    required MultimediaItem item,
    required int position,
    required int duration,
    String? episodeUrl,
    int? episodeNumber,
    String? episodeTitle,
    String? episodePosterUrl,
  }) async {
    if (!isSignedIn) return;
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(item.url);
    final episodeId = episodeUrl == null
        ? null
        : AnimeWitcherSyncIds.episodeIdFromUrl(episodeUrl);
    final profile = _profile;
    if (animeId == null || profile == null) return;
    return _enqueueProgressWrite(
      animeId,
      () => _saveProgressInternal(
        item: item,
        animeId: animeId,
        episodeId: episodeId,
        profile: profile,
        position: position,
        duration: duration,
        episodeUrl: episodeUrl,
        episodeNumber: episodeNumber,
        episodeTitle: episodeTitle,
        episodePosterUrl: episodePosterUrl,
      ),
    );
  }

  Future<void> saveContinueWatchingProgress({
    required MultimediaItem item,
    required int position,
    required int duration,
    String? episodeUrl,
    int? episodeNumber,
    String? episodeTitle,
    String? episodePosterUrl,
  }) async {
    if (!isSignedIn) return;
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(item.url);
    final episodeId = episodeUrl == null
        ? null
        : AnimeWitcherSyncIds.episodeIdFromUrl(episodeUrl);
    final profile = _profile;
    if (animeId == null || profile == null) return;
    return _enqueueProgressWrite(
      animeId,
      () => _saveProgressInternal(
        item: item,
        animeId: animeId,
        episodeId: episodeId,
        profile: profile,
        position: position,
        duration: duration,
        episodeUrl: episodeUrl,
        episodeNumber: episodeNumber,
        episodeTitle: episodeTitle,
        episodePosterUrl: episodePosterUrl,
        updateLastWatched: false,
      ),
    );
  }

  Future<void> _saveProgressInternal({
    required MultimediaItem item,
    required String animeId,
    required String? episodeId,
    required AnimeWitcherProfile profile,
    required int position,
    required int duration,
    required String? episodeUrl,
    required int? episodeNumber,
    required String? episodeTitle,
    required String? episodePosterUrl,
    bool updateLastWatched = true,
  }) async {
    if (!_isCurrentProfile(profile)) return;
    final progress = duration > 0
        ? ((position / duration) * 100).round().clamp(0, 100)
        : 0;
    // AnimeWitcher rewinds the cloud resume point by two seconds. This avoids
    // reopening immediately after the last spoken line or scene transition.
    final cloudStopPosition = (position - 2000).clamp(0, position).toInt();
    final operations = <Future<void>>[];

    if (episodeId != null) {
      operations.add(
        _authenticated(
          (token) => _firestore
              .setDocument(
                'users/${profile.documentId}/episodes_watched/$animeId/'
                'stop_times/$episodeId',
                <String, dynamic>{'stop_time': cloudStopPosition},
                token,
              )
              .then((_) {}),
        ),
      );
    }

    operations.add(
      _authenticated(
        (token) => _firestore
            .setDocumentWithServerTimestamps(
              'users/${profile.documentId}/continue_watching/$animeId',
              <String, dynamic>{
                'episode_id': episodeId ?? '',
                'episode_name': episodeTitle ??
                    (episodeNumber == null
                        ? ''
                        : formatEpisodeNumberLabel(
                            episode: episodeNumber,
                            isArabic: true,
                            isFinal: hasFinalEpisodeSuffix(episodeTitle),
                          )),
                'anime_name': item.title,
                'anime_type': item.contentType.name,
                'anime_id': animeId,
                'poster': episodePosterUrl ?? item.posterUrl,
                'progress': progress,
                // Additive AnimeWitcher fields preserve exact resume state while
                // remaining fully readable by the official app.
                'position': position,
                'duration': duration,
                'main_url': item.url,
                'episode_url': episodeUrl ?? '',
                'episode_number': episodeNumber ?? 0,
                'banner': item.bannerUrl ?? '',
                'provider': item.provider ?? animeWitcherProvider,
                'animewitcher_item': _compactItem(item),
              },
              token,
              serverTimestampFields: const <String>{'date_updated'},
            )
            .then((_) {}),
      ),
    );
    if (updateLastWatched) {
      operations.add(
        _authenticated(
          (token) => _firestore
              .setDocumentWithServerTimestamps(
                'users/${profile.documentId}/last_watched/$animeId',
                <String, dynamic>{'anime_id': animeId},
                token,
                serverTimestampFields: const <String>{'date'},
              )
              .then((_) {}),
        ),
      );
    }
    await Future.wait(operations);
    if (!_isCurrentProfile(profile)) return;
    final syncedAt = DateTime.now().millisecondsSinceEpoch;
    await _storage.markContinueWatchingItemSynced(
      item.url,
      accountUid: profile.uid,
      syncedAt: syncedAt,
    );
    if (updateLastWatched) {
      await _storage.markHistoryItemSynced(
        item.url,
        accountUid: profile.uid,
        syncedAt: syncedAt,
      );
    }
    if (episodeId != null) {
      _stopTimeCache['$animeId|$episodeId'] = cloudStopPosition;
    }
  }

  Future<void> _enqueueProgressWrite(
    String animeId,
    Future<void> Function() write,
  ) {
    final previous = _progressWriteQueues[animeId] ?? Future<void>.value();
    late final Future<void> operation;
    operation = previous.then<void>(
      (_) => write(),
      onError: (Object _, StackTrace __) => write(),
    );
    _progressWriteQueues[animeId] = operation;
    return operation.whenComplete(() {
      if (identical(_progressWriteQueues[animeId], operation)) {
        _progressWriteQueues.remove(animeId);
      }
    });
  }

  Future<void> removeContinueWatching(String mainUrl) async {
    final animeId = AnimeWitcherSyncIds.animeIdFromUrl(mainUrl);
    final profile = _profile;
    if (animeId == null || profile == null) return;
    final mutationId = _pendingMutationId(animeId);
    final revision = _nextMutationRevision();
    await _mutatePending(_pendingContinueDeletesKey, (values) {
      values[mutationId] = <String, dynamic>{
        'anime_id': animeId,
        'owner_uid': profile.uid,
        'revision': revision,
      };
    });
    if (!isSignedIn) return;
    await _deleteContinueWatchingRemote(animeId, profile);
    await _removePendingMutation(
      _pendingContinueDeletesKey,
      mutationId,
      revision,
    );
  }

  Future<void> _deleteContinueWatchingRemote(
    String animeId,
    AnimeWitcherProfile profile,
  ) {
    return _enqueueProgressWrite(
      animeId,
      () {
        if (!_isCurrentProfile(profile)) return Future<void>.value();
        return _authenticated(
          (token) => _firestore.deleteDocument(
            'users/${profile.documentId}/continue_watching/$animeId',
            token,
          ),
        );
      },
    );
  }

  Future<void> _flushPendingContinueDeletes(
    AnimeWitcherProfile profile,
  ) async {
    final pending = _readPendingMutations(_pendingContinueDeletesKey);
    for (final entry in pending.entries) {
      if (!_isCurrentProfile(profile)) return;
      final mutation = entry.value;
      if (!_mutationBelongsToProfile(mutation, profile)) continue;
      final animeId = _optionalString(mutation['anime_id']);
      final revision = _optionalString(mutation['revision']);
      if (animeId == null || revision == null) continue;
      await _deleteContinueWatchingRemote(animeId, profile);
      await _removePendingMutation(
        _pendingContinueDeletesKey,
        entry.key,
        revision,
      );
    }
  }

  Future<void> _syncContinueWatching() async {
    final profile = _profile!;
    await _pendingStorageWrite;
    await _flushPendingContinueDeletes(profile);
    if (!_isCurrentProfile(profile)) return;
    final remoteDocs = await _authenticated(
      (token) => _firestore.listDocuments(
        'users/${profile.documentId}/continue_watching',
        token,
      ),
    );
    if (!_isCurrentProfile(profile)) return;

    final localByAnime = <String, Map<String, dynamic>>{};
    for (final raw in _storage.getContinueWatching()) {
      final id = AnimeWitcherSyncIds.animeIdFromUrl(
        (raw['url'] ?? '').toString(),
      );
      if (id != null) localByAnime[id] = raw;
    }
    final remoteByAnime = <String, FirestoreDocument>{};
    for (final document in remoteDocs) {
      final animeId =
          _optionalString(document.fields['anime_id']) ?? document.id;
      remoteByAnime[animeId] = document;
    }

    for (final entry in remoteByAnime.entries) {
      if (!_isCurrentProfile(profile)) return;
      final animeId = entry.key;
      final fields = entry.value.fields;
      final remoteDate = _dateValue(fields['date_updated']);
      final local = localByAnime[animeId];
      final resolution = resolveAnimeWitcherSyncConflict(
        remoteExists: true,
        localUpdatedAt: local == null ? 0 : _intValue(local['timestamp']),
        remoteUpdatedAt: remoteDate?.millisecondsSinceEpoch ?? 0,
        syncedAccountUid: _optionalString(local?['animeWitcherSyncedUid']),
        localSyncedAt: _intValue(local?['animeWitcherSyncedAt']),
        currentAccountUid: profile.uid,
      );
      if (local != null &&
          resolution == AnimeWitcherSyncResolution.uploadLocal &&
          _hasMeaningfulPlayback(local)) {
        await _uploadContinueWatchingEntry(local, profile);
        continue;
      }
      await _importRemoteContinueWatchingEntry(
        animeId: animeId,
        fields: fields,
        profile: profile,
        remoteDate: remoteDate,
      );
    }

    for (final entry in localByAnime.entries) {
      if (!_isCurrentProfile(profile)) return;
      if (remoteByAnime.containsKey(entry.key)) continue;
      final raw = entry.value;
      final resolution = resolveAnimeWitcherSyncConflict(
        remoteExists: false,
        localUpdatedAt: _intValue(raw['timestamp']),
        remoteUpdatedAt: 0,
        syncedAccountUid: _optionalString(raw['animeWitcherSyncedUid']),
        localSyncedAt: _intValue(raw['animeWitcherSyncedAt']),
        currentAccountUid: profile.uid,
      );
      if (resolution == AnimeWitcherSyncResolution.deleteLocal) {
        final url = _optionalString(raw['url']);
        if (url != null) await _storage.removeFromContinueWatching(url);
        continue;
      }
      if (_hasMeaningfulPlayback(raw)) {
        await _uploadContinueWatchingEntry(raw, profile);
      }
    }
  }

  Future<void> _uploadContinueWatchingEntry(
    Map<String, dynamic> raw,
    AnimeWitcherProfile profile,
  ) async {
    if (!_isCurrentProfile(profile)) return;
    final item = _itemFromHistory(raw);
    if (item == null) return;
    await saveContinueWatchingProgress(
      item: item,
      position: _intValue(raw['position']),
      duration: _intValue(raw['duration']),
      episodeUrl: _optionalString(raw['lastEpisodeUrl']),
      episodeNumber: _nullableInt(raw['episode']),
      episodeTitle: _optionalString(raw['episodeTitle']),
      episodePosterUrl: _optionalString(raw['episodePosterUrl']),
    );
  }

  Future<void> _importRemoteContinueWatchingEntry({
    required String animeId,
    required Map<String, dynamic> fields,
    required AnimeWitcherProfile profile,
    required DateTime? remoteDate,
  }) async {
    final item =
        _itemFromCompact(fields['animewitcher_item']) ??
        await _itemForAnimeId(animeId);
    if (item == null || !_isCurrentProfile(profile)) return;
    final episodeId = _optionalString(fields['episode_id']);
    final episodeUrl =
        _optionalString(fields['episode_url']) ??
        (episodeId == null
            ? null
            : AnimeWitcherSyncIds.episodeUrl(animeId, episodeId));
    Map<String, dynamic>? previousLocal;
    for (final raw in _storage.getContinueWatching()) {
      final localAnimeId = AnimeWitcherSyncIds.animeIdFromUrl(
        (raw['url'] ?? '').toString(),
      );
      if (localAnimeId == animeId) {
        previousLocal = raw;
        break;
      }
    }
    final sameEpisode = episodeUrl != null &&
        _optionalString(previousLocal?['lastEpisodeUrl']) == episodeUrl;
    final previousPosition =
        sameEpisode ? _intValue(previousLocal?['position']) : 0;
    final previousDuration =
        sameEpisode ? _intValue(previousLocal?['duration']) : 0;

    var stopTimePosition = 0;
    if (episodeId != null) {
      final stop = await _authenticated(
        (token) => _firestore.getDocument(
          'users/${profile.documentId}/episodes_watched/$animeId/'
          'stop_times/$episodeId',
          token,
        ),
      );
      stopTimePosition = _intValue(stop?.fields['stop_time']);
    }
    var position = stopTimePosition;
    if (position <= 0) position = _intValue(fields['position']);
    final remoteProgress = _intValue(fields['progress']).clamp(0, 100);
    var duration = _intValue(fields['duration']);
    if (duration <= 0 && position > 0 && remoteProgress > 0) {
      final watchedForEstimate =
          stopTimePosition > 0 ? stopTimePosition + 2000 : position;
      if (remoteProgress <= 2 && previousDuration > 0) {
        duration = previousDuration;
      } else if (remoteProgress >= 100) {
        duration = watchedForEstimate;
      } else {
        final minimumDuration =
            (watchedForEstimate * 100) / (remoteProgress + 1);
        final maximumDuration = (watchedForEstimate * 100) / remoteProgress;
        duration = ((minimumDuration + maximumDuration) / 2).round();
      }
    }
    if (duration <= 0 && previousDuration > 0) duration = previousDuration;
    if (position <= 0 && duration > 0 && remoteProgress > 0) {
      position = ((duration * remoteProgress) / 100).round();
    }
    if (position <= 0 && remoteProgress == 0 && previousPosition > 0) {
      position = previousPosition;
    }
    final syncedAt =
        remoteDate?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch;
    await _storage.saveContinueWatchingProgress(
      item,
      position,
      duration,
      lastEpisodeUrl: episodeUrl,
      episode: _cloudEpisodeNumber(fields),
      episodeTitle: _optionalString(fields['episode_name']),
      episodePosterUrl: _optionalString(fields['poster']),
      progressPercent: remoteProgress,
      timestamp: syncedAt,
      syncedAccountUid: profile.uid,
      syncedAt: syncedAt,
    );
    if (episodeId != null) {
      _stopTimeCache['$animeId|$episodeId'] = position;
    }
  }

  bool _hasMeaningfulPlayback(Map<String, dynamic>? raw) {
    if (raw == null) return false;
    return _intValue(raw['position']) > 0 ||
        _intValue(raw['duration']) > 0 ||
        (_optionalString(raw['lastEpisodeUrl'])?.isNotEmpty ?? false);
  }

  // -------------------------------------------------------------------------
  // Mapping helpers
  // -------------------------------------------------------------------------

  Future<MultimediaItem?> _itemForAnimeId(String animeId) async {
    final document = await _authenticated(
      (token) => _firestore.getDocument('anime_list/$animeId', token),
    );
    if (document == null) return null;
    final own = _itemFromCompact(document.fields['animewitcher_item']);
    if (own != null) return own;
    final source = document.fields;
    final details = _map(source['details']);
    final poster = _map(source['poster']);
    final title = _optionalString(source['name']) ??
        _optionalString(source['english_title']) ??
        animeId;
    final posterUrl = _firstString(<dynamic>[
      poster['large'],
      source['poster_uri'],
      poster['medium'],
      source['cover_uri'],
    ]);
    final banner = _firstString(<dynamic>[
      source['cover_uri'],
      poster['large'],
      source['poster_uri'],
    ]);
    final rawType = _firstString(<dynamic>[source['type'], details['type']]);
    final isMovie = rawType.toLowerCase().contains('movie') ||
        rawType.contains('فيلم');
    return MultimediaItem(
      title: title,
      url: AnimeWitcherSyncIds.mainUrl(animeId),
      posterUrl: posterUrl,
      bannerUrl: banner.isEmpty ? posterUrl : banner,
      description: _optionalString(source['story']) ??
          _optionalString(source['description']) ??
          _optionalString(details['story']),
      contentType:
          isMovie ? MultimediaContentType.movie : MultimediaContentType.anime,
      provider: animeWitcherProvider,
      year: _yearValue(details['year'] ?? source['year']),
      score: _doubleValue(details['mal_mean'] ?? details['mal_score']),
    );
  }

  Map<String, dynamic> _compactItem(MultimediaItem item) => <String, dynamic>{
    'title': item.title,
    'url': item.url,
    'posterUrl': item.posterUrl,
    'bannerUrl': item.bannerUrl,
    'description': item.description,
    'type': item.contentType.name,
    'provider': item.provider ?? animeWitcherProvider,
    'status': item.status.name,
    'year': item.year,
    'score': item.score,
    'tmdbId': item.tmdbId,
    'imdbId': item.imdbId,
  };

  MultimediaItem? _itemFromCompact(dynamic raw) {
    final source = _map(raw);
    if (source.isEmpty || _optionalString(source['url']) == null) return null;
    try {
      return MultimediaItem.fromJson(source);
    } catch (_) {
      return null;
    }
  }

  MultimediaItem? _itemFromHistory(Map<String, dynamic> raw) {
    final url = _optionalString(raw['url']);
    if (url == null || AnimeWitcherSyncIds.animeIdFromUrl(url) == null) {
      return null;
    }
    return MultimediaItem(
      title: (raw['title'] ?? '').toString(),
      url: url,
      posterUrl: (raw['posterUrl'] ?? '').toString(),
      bannerUrl: _optionalString(raw['bannerUrl']),
      description: _optionalString(raw['description']),
      contentType: MultimediaItem.parseContentType(
        (raw['contentType'] ?? raw['type']).toString(),
      ),
      provider: _optionalString(raw['provider']) ?? animeWitcherProvider,
      tmdbId: _nullableInt(raw['tmdbId']),
      imdbId: _optionalString(raw['imdbId']),
    );
  }

  String? _animeIdFromFavorite(FirestoreDocument document) {
    final reference = _optionalString(
      document.fields['anime_doc_id'] ?? document.fields['doc_ref'],
    );
    if (reference == null) return document.id;
    return _lastPathSegment(reference);
  }

  String? _animeIdFromListDocument(FirestoreDocument document) {
    final reference = _optionalString(document.fields['doc_ref']);
    return reference == null ? document.id : _lastPathSegment(reference);
  }

  String _cloudType(LibraryCategory category) => switch (category) {
    LibraryCategory.watching => 'watching',
    LibraryCategory.continueLater => 'on_Hold',
    LibraryCategory.completed => 'completed',
    LibraryCategory.planToWatch => 'pin',
    LibraryCategory.notInterested => 'no_watching',
    LibraryCategory.favorite => 'pin',
  };

  LibraryCategory _categoryFromCloudType(dynamic raw) {
    return switch ((raw ?? '').toString()) {
      'watching' => LibraryCategory.watching,
      'completed' => LibraryCategory.completed,
      'no_watching' || 'noWatching' => LibraryCategory.notInterested,
      'on_Hold' || 'onHold' => LibraryCategory.continueLater,
      'pin' || 'pinned' => LibraryCategory.planToWatch,
      _ => LibraryCategory.planToWatch,
    };
  }

  bool _isCurrentProfile(AnimeWitcherProfile profile) {
    final current = _profile;
    return current != null &&
        current.documentId == profile.documentId &&
        current.uid == profile.uid;
  }

  bool _isCurrentSession(
    AnimeWitcherSession expected,
    int generation,
  ) {
    final current = _session;
    return generation == _sessionGeneration &&
        current != null &&
        current.uid == expected.uid;
  }

  String _lastSyncKey(String uid) =>
      'animewitcher_account_last_sync_v2:${Uri.encodeComponent(uid)}';
}

class _RemoteLibraryEntry {
  const _RemoteLibraryEntry({
    required this.category,
    required this.favorite,
    required this.document,
    required this.updatedAt,
  });

  final LibraryCategory? category;
  final bool favorite;
  final FirestoreDocument document;
  final DateTime? updatedAt;
}

Map<String, dynamic> _map(dynamic raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return <String, dynamic>{};
}

String? _optionalString(dynamic raw) {
  final value = raw?.toString().trim() ?? '';
  return value.isEmpty ? null : value;
}

List<String> _providerIdsFromUser(dynamic raw) {
  if (raw is! Iterable) return const <String>[];
  final providers = <String>{};
  for (final entry in raw) {
    if (entry is! Map) continue;
    final provider = _optionalString(entry['providerId']);
    if (provider != null) providers.add(provider);
  }
  return providers.toList(growable: false);
}

String _firstString(Iterable<dynamic> values) {
  for (final value in values) {
    final string = _optionalString(value);
    if (string != null) return string;
  }
  return '';
}

String _lastPathSegment(String value) {
  final parts = value.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) return value;
  final raw = parts.last;
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

String _emailName(String? email) {
  final value = email?.trim() ?? '';
  if (value.isEmpty) return 'AnimeWitcher User';
  return value.split('@').first;
}

int _intValue(dynamic raw) {
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

int? _nullableInt(dynamic raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw.toString());
}

double? _doubleValue(dynamic raw) {
  if (raw is num) return raw.toDouble();
  return double.tryParse(raw?.toString() ?? '');
}

int? _yearValue(dynamic raw) {
  final match = RegExp(r'\b(?:19|20)\d{2}\b').firstMatch(raw?.toString() ?? '');
  return match == null ? null : int.tryParse(match.group(0)!);
}

DateTime? _latestDate(DateTime? first, DateTime? second) {
  if (first == null) return second;
  if (second == null) return first;
  return first.isAfter(second) ? first : second;
}

DateTime? _dateValue(dynamic raw) {
  if (raw is DateTime) return raw;
  if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
  return DateTime.tryParse(raw?.toString() ?? '');
}

int? _cloudEpisodeNumber(Map<String, dynamic> fields) {
  final explicit = _nullableInt(fields['episode_number']);
  if (explicit != null && explicit > 0) return explicit;
  for (final raw in <dynamic>[
    fields['episode_id'],
    fields['episode_name'],
  ]) {
    final label = _optionalString(raw);
    if (label == null) continue;
    final normalized = label
        .replaceAllMapped(
          RegExp(r'[٠-٩]'),
          (match) => '${'٠١٢٣٤٥٦٧٨٩'.indexOf(match.group(0)!)}',
        )
        .replaceAllMapped(
          RegExp(r'[۰-۹]'),
          (match) => '${'۰۱۲۳۴۵۶۷۸۹'.indexOf(match.group(0)!)}',
        );
    final match = RegExp(r'\d+').firstMatch(normalized);
    final value = match == null ? null : int.tryParse(match.group(0)!);
    if (value != null && value > 0) return value;
  }
  return null;
}
