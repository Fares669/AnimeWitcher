import '../domain/entity/multimedia_item.dart';
import 'rating_score.dart';

enum CatalogRatingSource { mal, imdb, animeWitcher }

class CatalogRating {
  const CatalogRating({required this.source, required this.score});

  final CatalogRatingSource source;
  final double score;
}

/// Rating shown beside the catalog caption.
///
/// Source priority mirrors AnimeWitcher: MAL, then IMDb, then AnimeWitcher.
/// Values come from the already-loaded catalog payload. Latest-episode cards
/// keep their relative-time subtitle uncluttered and therefore omit ratings.
CatalogRating? preferredCatalogRating(MultimediaItem item) {
  final episodeBadge = item.episodeBadge?.trim() ?? '';
  if (episodeBadge.isNotEmpty) return null;

  final data = item.syncData ?? const <String, String>{};
  final mal = parsePositiveRatingScore(data['awMalScore']);
  if (mal != null) {
    return CatalogRating(source: CatalogRatingSource.mal, score: mal);
  }

  final imdb = parsePositiveRatingScore(
    data['awImdbScore'] ?? data['imdbRate'] ?? data['imdb_rate'],
  );
  if (imdb != null) {
    return CatalogRating(source: CatalogRatingSource.imdb, score: imdb);
  }

  final animeWitcher = parsePositiveRatingScore(data['awScore']);
  if (animeWitcher != null) {
    return CatalogRating(
      source: CatalogRatingSource.animeWitcher,
      score: animeWitcher,
    );
  }

  return null;
}

String formatCatalogRatingScore(double score) => formatRatingScore(score);
