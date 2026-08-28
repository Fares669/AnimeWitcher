/// Thrown when a signed-out user tries to change favorites or lists.
class LibrarySignInRequiredException implements Exception {
  const LibrarySignInRequiredException();
}

/// Favorites and lists are account-backed. Mutations require a session.
void requireLibrarySignIn(bool signedIn) {
  if (!signedIn) {
    throw const LibrarySignInRequiredException();
  }
}

String librarySignInRequiredMessage({required bool isArabic}) {
  return isArabic
      ? 'سجل الدخول لإضافة الأعمال إلى المفضلة والقوائم'
      : 'Sign in to add titles to favorites and lists';
}
