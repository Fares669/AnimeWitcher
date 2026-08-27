enum AnimeWitcherSignInMethod { email, google }

enum AnimeWitcherProfileImageKind { avatar, cover }

/// Account-owned visibility and content preferences stored in
/// `users/{id}.settings` by AnimeWitcher.
///
/// Missing fields deliberately keep the source application's historical
/// defaults so old profiles neither lose visibility nor hide catalog entries.
class AnimeWitcherPrivacySettings {
  const AnimeWitcherPrivacySettings({
    this.showFavoritesToUsers = true,
    this.showCommentsToUsers = true,
    this.showReviewsToUsers = true,
    this.hideEcchiAnime = false,
  });

  final bool showFavoritesToUsers;
  final bool showCommentsToUsers;
  final bool showReviewsToUsers;
  final bool hideEcchiAnime;

  AnimeWitcherPrivacySettings copyWith({
    bool? showFavoritesToUsers,
    bool? showCommentsToUsers,
    bool? showReviewsToUsers,
    bool? hideEcchiAnime,
  }) {
    return AnimeWitcherPrivacySettings(
      showFavoritesToUsers:
          showFavoritesToUsers ?? this.showFavoritesToUsers,
      showCommentsToUsers: showCommentsToUsers ?? this.showCommentsToUsers,
      showReviewsToUsers: showReviewsToUsers ?? this.showReviewsToUsers,
      hideEcchiAnime: hideEcchiAnime ?? this.hideEcchiAnime,
    );
  }

  /// Keys match the public AnimeWitcher Firestore profile schema exactly.
  Map<String, dynamic> toFirestoreJson() => <String, dynamic>{
        'show_fav_to_users': showFavoritesToUsers,
        'show_comments_to_users': showCommentsToUsers,
        'show_reviews_to_users': showReviewsToUsers,
        'hide_ecchi_anime': hideEcchiAnime,
      };

  Map<String, dynamic> toJson() => toFirestoreJson();

  factory AnimeWitcherPrivacySettings.fromJson(dynamic raw) {
    if (raw is! Map) return const AnimeWitcherPrivacySettings();
    final values = raw.map<String, dynamic>(
      (key, value) => MapEntry(key.toString(), value),
    );
    bool read(String key, bool fallback) {
      final value = values[key];
      return value is bool ? value : fallback;
    }
    return AnimeWitcherPrivacySettings(
      showFavoritesToUsers: read('show_fav_to_users', true),
      showCommentsToUsers: read('show_comments_to_users', true),
      showReviewsToUsers: read('show_reviews_to_users', true),
      hideEcchiAnime: read('hide_ecchi_anime', false),
    );
  }
}

class AnimeWitcherSession {
  const AnimeWitcherSession({
    required this.uid,
    required this.idToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.signInMethod,
    this.email,
    this.displayName,
    this.photoUrl,
    this.providerIds = const <String>[],
  });

  final String uid;
  final String idToken;
  final String refreshToken;
  final DateTime expiresAt;
  final AnimeWitcherSignInMethod signInMethod;
  final String? email;
  final String? displayName;
  final String? photoUrl;
  final List<String> providerIds;

  bool get needsRefresh =>
      DateTime.now().add(const Duration(minutes: 2)).isAfter(expiresAt);

  AnimeWitcherSession copyWith({
    String? uid,
    String? idToken,
    String? refreshToken,
    DateTime? expiresAt,
    AnimeWitcherSignInMethod? signInMethod,
    String? email,
    String? displayName,
    String? photoUrl,
    List<String>? providerIds,
  }) {
    return AnimeWitcherSession(
      uid: uid ?? this.uid,
      idToken: idToken ?? this.idToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
      signInMethod: signInMethod ?? this.signInMethod,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      photoUrl: photoUrl ?? this.photoUrl,
      providerIds: providerIds ?? this.providerIds,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'uid': uid,
    'idToken': idToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'signInMethod': signInMethod.name,
    'email': email,
    'displayName': displayName,
    'photoUrl': photoUrl,
    'providerIds': providerIds,
  };

  factory AnimeWitcherSession.fromJson(Map<String, dynamic> json) {
    return AnimeWitcherSession(
      uid: (json['uid'] ?? '').toString(),
      idToken: (json['idToken'] ?? '').toString(),
      refreshToken: (json['refreshToken'] ?? '').toString(),
      expiresAt:
          DateTime.tryParse((json['expiresAt'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      signInMethod:
          (json['signInMethod'] ?? '').toString().toLowerCase() == 'google'
          ? AnimeWitcherSignInMethod.google
          : AnimeWitcherSignInMethod.email,
      email: _optionalString(json['email']),
      displayName: _optionalString(json['displayName']),
      photoUrl: _optionalString(json['photoUrl']),
      providerIds: _stringList(json['providerIds']),
    );
  }
}

class AnimeWitcherProfile {
  const AnimeWitcherProfile({
    required this.documentId,
    required this.uid,
    required this.signInMethod,
    this.email,
    this.userName,
    this.photoUrl,
    this.coverUrl,
    this.bio,
    this.country,
    this.birthYear,
    this.providerIds = const <String>[],
    this.privacySettings = const AnimeWitcherPrivacySettings(),
  });

  final String documentId;
  final String uid;
  final AnimeWitcherSignInMethod signInMethod;
  final String? email;
  final String? userName;
  final String? photoUrl;
  final String? coverUrl;
  final String? bio;
  final String? country;
  final String? birthYear;
  final List<String> providerIds;
  final AnimeWitcherPrivacySettings privacySettings;

  bool get hasPasswordProvider => providerIds.contains('password');
  bool get hasGoogleProvider => providerIds.contains('google.com');

  AnimeWitcherProfile copyWith({
    String? documentId,
    String? uid,
    AnimeWitcherSignInMethod? signInMethod,
    String? email,
    String? userName,
    String? photoUrl,
    String? coverUrl,
    String? bio,
    String? country,
    String? birthYear,
    List<String>? providerIds,
    AnimeWitcherPrivacySettings? privacySettings,
    bool clearPhotoUrl = false,
    bool clearCoverUrl = false,
    bool clearBio = false,
    bool clearCountry = false,
    bool clearBirthYear = false,
  }) {
    return AnimeWitcherProfile(
      documentId: documentId ?? this.documentId,
      uid: uid ?? this.uid,
      signInMethod: signInMethod ?? this.signInMethod,
      email: email ?? this.email,
      userName: userName ?? this.userName,
      photoUrl: clearPhotoUrl ? null : (photoUrl ?? this.photoUrl),
      coverUrl: clearCoverUrl ? null : (coverUrl ?? this.coverUrl),
      bio: clearBio ? null : (bio ?? this.bio),
      country: clearCountry ? null : (country ?? this.country),
      birthYear: clearBirthYear ? null : (birthYear ?? this.birthYear),
      providerIds: providerIds ?? this.providerIds,
      privacySettings: privacySettings ?? this.privacySettings,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'documentId': documentId,
    'uid': uid,
    'signInMethod': signInMethod.name,
    'email': email,
    'userName': userName,
    'photoUrl': photoUrl,
    'coverUrl': coverUrl,
    'bio': bio,
    'country': country,
      'birthYear': birthYear,
      'providerIds': providerIds,
      'privacySettings': privacySettings.toJson(),
  };

  factory AnimeWitcherProfile.fromJson(Map<String, dynamic> json) {
    return AnimeWitcherProfile(
      documentId: (json['documentId'] ?? '').toString(),
      uid: (json['uid'] ?? '').toString(),
      signInMethod:
          (json['signInMethod'] ?? '').toString().toLowerCase() == 'google'
          ? AnimeWitcherSignInMethod.google
          : AnimeWitcherSignInMethod.email,
      email: _optionalString(json['email']),
      userName: _optionalString(json['userName']),
      photoUrl: _optionalString(json['photoUrl']),
      coverUrl: _optionalString(json['coverUrl']),
      bio: _optionalString(json['bio']),
      country: _optionalString(json['country']),
      birthYear: _optionalString(json['birthYear']),
      providerIds: _stringList(json['providerIds']),
      privacySettings: AnimeWitcherPrivacySettings.fromJson(
        json['privacySettings'] ?? json['settings'],
      ),
    );
  }
}

class AnimeWitcherAccountSnapshot {
  const AnimeWitcherAccountSnapshot({
    this.profile,
    this.lastSyncAt,
  });

  final AnimeWitcherProfile? profile;
  final DateTime? lastSyncAt;

  bool get isSignedIn => profile != null;

  AnimeWitcherAccountSnapshot copyWith({
    AnimeWitcherProfile? profile,
    DateTime? lastSyncAt,
    bool clearProfile = false,
  }) {
    return AnimeWitcherAccountSnapshot(
      profile: clearProfile ? null : (profile ?? this.profile),
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }
}

class AnimeWitcherAccountException implements Exception {
  const AnimeWitcherAccountException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

String? _optionalString(dynamic raw) {
  final value = raw?.toString().trim() ?? '';
  return value.isEmpty ? null : value;
}

List<String> _stringList(dynamic raw) {
  if (raw is! Iterable) return const <String>[];
  return raw
      .map((value) => value?.toString().trim() ?? '')
      .where((value) => value.isNotEmpty)
      .toSet()
      .toList(growable: false);
}
