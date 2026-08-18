import 'package:flutter/foundation.dart';

/// Build-time client configuration for AnimeWitcher account synchronization.
///
/// Firebase client keys are identifiers rather than authorization secrets, but
/// they must not be committed as an unrestricted shared credential. Release
/// builds receive these values through `--dart-define-from-file` and GitHub
/// Actions secrets.
class AnimeWitcherAccountConfig {
  const AnimeWitcherAccountConfig._();

  static const Set<String> trustedRegistrationEmailDomains = <String>{
    'gmail.com',
    'outlook.com',
    'yahoo.com',
  };

  static const String _projectIdOverride = String.fromEnvironment(
    'ANIMEWITCHER_FIREBASE_PROJECT_ID',
  );

  /// GitHub preview workflows always emit the define, even when the matching
  /// secret is absent. Preserve AnimeWitcher's known public project in that
  /// empty-override case instead of producing an invalid Firestore URL.
  static const String projectId = _projectIdOverride == ''
      ? 'animewitcher-1c66d'
      : _projectIdOverride;

  static const String apiKey = String.fromEnvironment(
    'ANIMEWITCHER_FIREBASE_API_KEY',
  );

  /// AnimeWitcher's bucket is a public Firebase client identifier. Keeping a
  /// build-time override makes previews and tests usable with another project
  /// without adding the native Firebase SDK to iOS.
  static const String storageBucket = String.fromEnvironment(
    'ANIMEWITCHER_FIREBASE_STORAGE_BUCKET',
    defaultValue: 'animewitcher-1c66d.appspot.com',
  );

  static const String functionsRegion = String.fromEnvironment(
    'ANIMEWITCHER_FIREBASE_FUNCTIONS_REGION',
    defaultValue: 'us-central1',
  );

  /// OAuth web/server client used to request a Google ID token which Firebase
  /// can exchange for an AnimeWitcher session.
  static const String googleServerClientId = String.fromEnvironment(
    'ANIMEWITCHER_GOOGLE_SERVER_CLIENT_ID',
  );

  /// iOS requires an OAuth client registered for SkyStream's bundle ID.
  static const String googleIosClientId = String.fromEnvironment(
    'ANIMEWITCHER_GOOGLE_IOS_CLIENT_ID',
  );

  /// Credentials sufficient for the proven Firebase REST endpoints.
  static bool get firebaseConfigured =>
      projectId.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  /// Public Firestore catalog reads only need the Firebase project id. The
  /// API key is used by Firebase Auth, not as authorization for Firestore.
  static bool get firestoreConfigured => projectId.trim().isNotEmpty;

  static bool get storageConfigured =>
      firebaseConfigured && storageBucket.trim().isNotEmpty;

  /// The official AnimeWitcher registration screen accepts these three mail
  /// providers. Sign-in itself remains open to existing legacy accounts.
  static bool isTrustedRegistrationEmail(String email) {
    final normalized = email.trim().toLowerCase();
    final separator = normalized.lastIndexOf('@');
    if (separator <= 0 || separator == normalized.length - 1) return false;
    return trustedRegistrationEmailDomains.contains(
      normalized.substring(separator + 1),
    );
  }

  static bool get googleConfigured {
    if (!firebaseConfigured) return false;
    if (kIsWeb) return googleServerClientId.trim().isNotEmpty;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS =>
        googleIosClientId.trim().isNotEmpty &&
            googleServerClientId.trim().isNotEmpty,
      TargetPlatform.android => googleServerClientId.trim().isNotEmpty,
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.fuchsia => false,
    };
  }
}
