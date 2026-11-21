/// Folds Arabic letters so provider titles can be matched despite differences
/// in hamza, taa marbuta, and diacritics.
String normalizeHomeSectionTitle(String title) {
  return title
      .toLowerCase()
      .replaceAll(RegExp(r'[ً-ٰٟ]'), '')
      .replaceAll(RegExp(r'[أإآ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll(RegExp(r' +'), ' ')
      .trim();
}

bool isLatestEpisodesSectionTitle(String title) {
  final normalized = normalizeHomeSectionTitle(title);
  return const [
    'احدث الحلقات',
    'اخر الحلقات',
    'الحلقات الجديده',
    'حلقات جديده',
    'new episodes',
    'latest episodes',
    'recent episodes',
  ].any(normalized.contains);
}
