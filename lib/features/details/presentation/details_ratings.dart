import '../../../core/account/animewitcher_comment_models.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/utils/digit_normalization.dart';

enum ExternalRatingSource { mal, imdb }

/// Parsed APK details ratings fields for the details page row.
///
/// Witcher score is `rating.rate`. MAL is the primary external score; when
/// AnimeWitcher's APK has no usable MAL score it falls back to
/// `details.imdb_rate`. Vote counts are never invented.
class AnimeDetailsRatings {
  const AnimeDetailsRatings({
    required this.animeId,
    this.witcherScore,
    this.witcherVoteCount,
    this.malMean,
    this.malScoringUsers,
    this.malId,
    this.imdbId,
    this.imdbScore,
    this.isUnaired = false,
    this.reviewsClosed = false,
  });

  final String animeId;
  final double? witcherScore;
  final int? witcherVoteCount;
  final double? malMean;
  final int? malScoringUsers;
  final String? malId;
  final String? imdbId;
  final double? imdbScore;
  final bool isUnaired;
  final bool reviewsClosed;

  /// External score source, matching the APK's MAL -> IMDb fallback.
  ///
  /// Prefer a real MAL id + mean. If MAL is unavailable, an IMDb id +
  /// `imdb_rate` is used. The final MAL branch preserves older AnimeWitcher
  /// payloads that exposed `mal_mean` alongside only an IMDb id.
  ExternalRatingSource? get externalSource {
    if (malMean != null && _hasId(malId)) {
      return ExternalRatingSource.mal;
    }
    if (imdbScore != null && _hasId(imdbId)) {
      return ExternalRatingSource.imdb;
    }
    if (malMean != null && _hasId(imdbId)) {
      return ExternalRatingSource.mal;
    }
    return null;
  }

  bool get showExternalColumn => externalSource != null;
  bool get showMalColumn => externalSource == ExternalRatingSource.mal;
  bool get showImdbColumn => externalSource == ExternalRatingSource.imdb;

  double? get externalScore => switch (externalSource) {
    ExternalRatingSource.mal => malMean,
    ExternalRatingSource.imdb => imdbScore,
    null => null,
  };

  /// Displayed MAL scoring-user count. IMDb has no scoring-user field in the
  /// AnimeWitcher APK model, so no count is invented for the fallback.
  int? get displayedMalScoringUsers {
    if (!showMalColumn) return null;
    if (isUnaired) return 0;
    return malScoringUsers;
  }

  int? get displayedExternalScoringUsers =>
      showMalColumn ? displayedMalScoringUsers : null;

  bool get canRate => !isUnaired && animeId.isNotEmpty;

  factory AnimeDetailsRatings.fromItem(MultimediaItem item) {
    final data = item.syncData ?? const <String, String>{};
    final isWitcherItem = isAnimeWitcherAccountItem(item);
    final malId = _firstNonEmpty(<String?>[
      data['malId'],
      data['mal_id'],
      data['awMalId'],
    ]);
    final imdbId = _firstNonEmpty(<String?>[
      data['awImdbId'],
      data['imdbId'],
      data['imdb_id'],
      item.imdbId,
    ]);
    return AnimeDetailsRatings(
      animeId: animeWitcherAnimeIdFromItem(item),
      witcherScore: isWitcherItem ? _positiveScore(data['awScore']) : null,
      witcherVoteCount: isWitcherItem
          ? _positiveInt(data['awScoreCount'])
          : null,
      malMean: _positiveScore(data['awMalScore']),
      malScoringUsers: _nonNegativeInt(data['awMalScoringUsers']),
      malId: malId,
      imdbId: imdbId,
      imdbScore: _positiveScore(
        data['awImdbScore'] ?? data['imdbRate'] ?? data['imdb_rate'],
      ),
      isUnaired: _isUnaired(item, data),
      reviewsClosed: isWitcherItem && _isTruthy(data['awReviewsClosed']),
    );
  }
}

String formatRatingScore(double score) {
  return score
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'[.]$'), '');
}

bool _hasId(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty || text == '0') return false;
  return true;
}

bool _isUnaired(MultimediaItem item, Map<String, String> data) {
  if (item.status == ShowStatus.upcoming) return true;
  final state = (data['awState'] ?? '').trim();
  return state == 'لم يتم بثه بعد';
}

bool _isTruthy(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  return value == 'true' || value == '1' || value == 'yes';
}

double? _positiveScore(String? raw) {
  final normalized = normalizeLocalizedDigits((raw ?? '').trim());
  if (normalized.isEmpty) return null;
  final match = RegExp(r'[0-9]+(?:[.][0-9]+)?').firstMatch(normalized);
  final score = match == null ? null : double.tryParse(match.group(0)!);
  if (score == null || score <= 0) return null;
  return score;
}

int? _positiveInt(String? raw) {
  final value = _nonNegativeInt(raw);
  if (value == null || value <= 0) return null;
  return value;
}

int? _nonNegativeInt(String? raw) {
  final normalized = normalizeLocalizedDigits((raw ?? '').trim());
  if (normalized.isEmpty) return null;
  final match = RegExp(r'[0-9]+').firstMatch(normalized);
  if (match == null) return null;
  return int.tryParse(match.group(0)!);
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final raw in values) {
    final value = raw?.trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return null;
}
