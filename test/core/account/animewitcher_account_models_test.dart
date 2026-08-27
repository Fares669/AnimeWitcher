import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';

void main() {
  test('account session survives secure-storage serialization', () {
    final original = AnimeWitcherSession(
      uid: 'uid-1',
      idToken: 'id-token',
      refreshToken: 'refresh-token',
      expiresAt: DateTime.utc(2026, 8, 9, 12),
      signInMethod: AnimeWitcherSignInMethod.google,
      email: 'user@example.com',
      displayName: 'Test User',
      photoUrl: 'https://example.com/photo.jpg',
      providerIds: const <String>['google.com', 'password'],
    );

    final restored = AnimeWitcherSession.fromJson(original.toJson());

    expect(restored.uid, original.uid);
    expect(restored.idToken, original.idToken);
    expect(restored.refreshToken, original.refreshToken);
    expect(restored.expiresAt, original.expiresAt);
    expect(restored.signInMethod, AnimeWitcherSignInMethod.google);
    expect(restored.email, original.email);
    expect(restored.displayName, original.displayName);
    expect(restored.photoUrl, original.photoUrl);
    expect(restored.providerIds, original.providerIds);
  });

  test('account profile preserves AnimeWitcher editable fields', () {
    const original = AnimeWitcherProfile(
      documentId: 'profile-1',
      uid: 'uid-1',
      signInMethod: AnimeWitcherSignInMethod.google,
      email: 'user@example.com',
      userName: 'Sky User',
      photoUrl: 'https://example.com/avatar.jpg',
      coverUrl: 'https://example.com/cover.jpg',
      bio: 'Anime fan',
      country: 'Palestine',
      birthYear: '1999',
      providerIds: <String>['google.com', 'password'],
    );

    final restored = AnimeWitcherProfile.fromJson(original.toJson());

    expect(restored.documentId, original.documentId);
    expect(restored.userName, original.userName);
    expect(restored.photoUrl, original.photoUrl);
    expect(restored.coverUrl, original.coverUrl);
    expect(restored.bio, original.bio);
    expect(restored.country, original.country);
    expect(restored.birthYear, original.birthYear);
    expect(restored.providerIds, original.providerIds);
    expect(restored.hasGoogleProvider, isTrue);
    expect(restored.hasPasswordProvider, isTrue);
  });

  test('privacy settings preserve documented values through profile storage', () {
    const privacy = AnimeWitcherPrivacySettings(
      showFavoritesToUsers: false,
      showCommentsToUsers: false,
      showReviewsToUsers: false,
      hideEcchiAnime: true,
    );
    const profile = AnimeWitcherProfile(
      documentId: 'profile-1',
      uid: 'uid-1',
      signInMethod: AnimeWitcherSignInMethod.email,
      privacySettings: privacy,
    );

    final restored = AnimeWitcherProfile.fromJson(profile.toJson());

    expect(restored.privacySettings.showFavoritesToUsers, isFalse);
    expect(restored.privacySettings.showCommentsToUsers, isFalse);
    expect(restored.privacySettings.showReviewsToUsers, isFalse);
    expect(restored.privacySettings.hideEcchiAnime, isTrue);
  });

  test('legacy profiles keep AnimeWitcher privacy defaults', () {
    final profile = AnimeWitcherProfile.fromJson(<String, dynamic>{
      'documentId': 'legacy-profile',
      'uid': 'uid-legacy',
      'signInMethod': 'email',
    });

    expect(profile.privacySettings.showFavoritesToUsers, isTrue);
    expect(profile.privacySettings.showCommentsToUsers, isTrue);
    expect(profile.privacySettings.showReviewsToUsers, isTrue);
    expect(profile.privacySettings.hideEcchiAnime, isFalse);
  });
}
