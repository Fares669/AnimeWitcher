import '../../../core/domain/entity/multimedia_item.dart';

/// Lowercases and folds Arabic letters so home rail titles from the catalog
/// can be matched without depending on hamza, taa marbuta, or diacritics.
String normalizeHomeSectionTitle(String title) {
  return title
      .toLowerCase()
      .replaceAll(RegExp(r'[ً-ٰٟ]'), '')
      .replaceAll(RegExp(r'[أإآ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll(RegExp(r' +'), ' ')
      .trim();
}

bool isLatestAddedSectionTitle(String title) {
  final normalized = normalizeHomeSectionTitle(title);
  return normalized.contains('اخر الاعمال المضافه') ||
      normalized.contains('الاعمال المضافه حديثا') ||
      normalized.contains('latest additions') ||
      normalized.contains('recently added');
}

bool isMostWatchedAnimationSectionTitle(String title) {
  final normalized = normalizeHomeSectionTitle(title);
  final isAnimation =
      normalized.contains('انميشن') ||
      normalized.contains('انيميشن') ||
      normalized.contains('animation');
  final isMostWatched =
      normalized.contains('الاكثر مشاهده') ||
      normalized.contains('most watched') ||
      normalized.contains('most viewed');
  return isAnimation && isMostWatched;
}

/// Catalog row titled **فصول جديدة** / New Chapters.
///
/// Distinct from **الحلقات الجديدة** (new anime episodes), which must stay
/// on home. Matching requires a chapters word plus a "new/latest" word.
bool isNewChaptersHomeSectionTitle(String title) {
  final normalized = normalizeHomeSectionTitle(title);
  final hasChapters =
      normalized.contains('فصول') ||
      normalized.contains('فصل') ||
      normalized.contains('chapter');
  if (!hasChapters) return false;
  return normalized.contains('جديد') ||
      normalized.contains('احدث') ||
      normalized.contains('new') ||
      normalized.contains('latest') ||
      normalized.contains('recent');
}

/// Rails that home should not show as a horizontal row.
///
/// `Trending` is the hero carousel. New Chapters is a broken catalog rail.
bool isHiddenHomeRailTitle(String title) {
  return title == 'Trending' || isNewChaptersHomeSectionTitle(title);
}

Iterable<MapEntry<String, List<MultimediaItem>>> visibleHomeRailEntries(
  Map<String, List<MultimediaItem>> data,
) {
  return data.entries.where((entry) => !isHiddenHomeRailTitle(entry.key));
}

/// Movies for the home hero. Hidden rails are never promoted into this slot
/// when the catalog omits a `Trending` key.
List<MultimediaItem>? homeHeroMovies(Map<String, List<MultimediaItem>> data) {
  if (data.containsKey('Trending')) return data['Trending'];
  for (final entry in data.entries) {
    if (isHiddenHomeRailTitle(entry.key)) continue;
    return entry.value;
  }
  return null;
}
