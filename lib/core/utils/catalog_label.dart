import '../domain/entity/multimedia_item.dart';
import 'relative_time.dart';

/// Server catalog type as written (`مسلسل`, `فيلم`, `خاصة`, `اونا`, `اوفا`),
/// falling back to a label derived from [MultimediaItem.contentType].
String? catalogTypeLabel(MultimediaItem item) {
  final raw = item.catalogType?.trim() ?? '';
  if (raw.isNotEmpty) return raw;
  switch (item.contentType) {
    case MultimediaContentType.movie:
      return 'فيلم';
    case MultimediaContentType.series:
    case MultimediaContentType.anime:
      return 'مسلسل';
    case MultimediaContentType.manga:
      return 'مانجا';
    case MultimediaContentType.livestream:
      return 'بث مباشر';
    case MultimediaContentType.other:
      return null;
  }
}

bool hasLatestEpisodeBadge(MultimediaItem item) {
  final badge = item.episodeBadge?.trim() ?? '';
  return badge.isNotEmpty;
}

/// Caption under a catalog poster: relative time for latest episodes,
/// otherwise the work type from the server.
String? multimediaCardSubtitle(MultimediaItem item) {
  if (hasLatestEpisodeBadge(item)) {
    final time = formatArabicRelativeTime(item.publishedAt);
    return time.isEmpty ? null : time;
  }
  return catalogTypeLabel(item);
}

/// Year overlay is hidden on latest-episode posters.
int? multimediaCardYear(MultimediaItem item) {
  if (hasLatestEpisodeBadge(item)) return null;
  final year = item.year;
  if (year == null || year <= 0) return null;
  return year;
}

String? dubbedPosterBadge(MultimediaItem item) {
  if (hasLatestEpisodeBadge(item) || !item.isDubbed) return null;
  return 'مدبلج';
}

String? relationPosterBadge(MultimediaItem item) {
  final explicit = item.relationLabel?.trim() ?? '';
  if (explicit.isNotEmpty) return explicit;

  final legacy = item.description?.trim() ?? '';
  const knownLegacyLabels = <String>{
    'previous',
    'next',
    'movie',
    'ova',
    'ona',
    'special',
    'side story',
    'spin-off',
    'alternative',
    'summary',
    'parent',
    'compilation',
    'adaptation',
    'related',
    'السابق',
    'التالي',
    'فيلم',
    'أوفا',
    'اوفا',
    'اونا',
    'خاصة',
    'قصة جانبية',
    'عمل مشتق',
    'نسخة بديلة',
    'ملخص',
    'العمل الأصلي',
    'تجميعة',
    'اقتباس مرتبط',
    'عمل مرتبط',
    'عمل مرتبط بالشخصيات',
    'موسم سابق',
    'موسم لاحق',
  };
  if (knownLegacyLabels.contains(legacy.toLowerCase())) return legacy;
  return null;
}

String? multimediaCardPosterBadge(
  MultimediaItem item, {
  bool showRelationBadge = false,
}) {
  if (showRelationBadge) {
    return relationPosterBadge(item) ?? dubbedPosterBadge(item);
  }
  return dubbedPosterBadge(item);
}
