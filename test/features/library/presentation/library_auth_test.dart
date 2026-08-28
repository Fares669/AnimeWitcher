import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/features/library/presentation/library_auth.dart';

void main() {
  test('blocks library mutations when the account is signed out', () {
    expect(
      () => requireLibrarySignIn(false),
      throwsA(isA<LibrarySignInRequiredException>()),
    );
  });

  test('allows library mutations when the account is signed in', () {
    expect(() => requireLibrarySignIn(true), returnsNormally);
  });

  test('uses Arabic copy for the sign-in requirement', () {
    expect(
      librarySignInRequiredMessage(isArabic: true),
      'سجل الدخول لإضافة الأعمال إلى المفضلة والقوائم',
    );
  });
}
