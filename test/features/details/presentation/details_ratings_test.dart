import 'dart:io';

import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/details_ratings.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item({
  String url = 'https://animewitcher.com/anime/naruto',
  ShowStatus status = ShowStatus.ongoing,
  Map<String, String>? syncData,
  String? imdbId,
}) {
  return MultimediaItem(
    title: 'Naruto',
    url: url,
    posterUrl: '',
    status: status,
    imdbId: imdbId,
    syncData: syncData,
  );
}

void main() {
  test('uses rating.rate and hides a missing Witcher vote count', () {
    final ratings = AnimeDetailsRatings.fromItem(
      _item(
        syncData: const <String, String>{
          'awScore': '8.73',
          'awMalScore': '7.5',
          'malId': '20',
        },
      ),
    );
    expect(ratings.witcherScore, 8.73);
    expect(ratings.witcherVoteCount, isNull);
    expect(ratings.showMalColumn, isTrue);
  });

  test('shows Witcher vote count only from a real count field', () {
    final ratings = AnimeDetailsRatings.fromItem(
      _item(
        syncData: const <String, String>{
          'awScore': '9.1',
          'awScoreCount': '668508',
        },
      ),
    );
    expect(ratings.witcherVoteCount, 668508);
  });

  test('hides MAL when neither mal_id nor imdb_id is present', () {
    final ratings = AnimeDetailsRatings.fromItem(
      _item(
        syncData: const <String, String>{'awScore': '8', 'awMalScore': '7.2'},
      ),
    );
    expect(ratings.showMalColumn, isFalse);
  });

  test('hides MAL when mal_mean is missing even if mal_id exists', () {
    final ratings = AnimeDetailsRatings.fromItem(
      _item(syncData: const <String, String>{'malId': '20', 'awScore': '8'}),
    );
    expect(ratings.showMalColumn, isFalse);
  });

  test('shows MAL when imdb_id and mal_mean exist', () {
    final ratings = AnimeDetailsRatings.fromItem(
      _item(
        imdbId: 'tt0409591',
        syncData: const <String, String>{'awMalScore': '8.11'},
      ),
    );
    expect(ratings.showMalColumn, isTrue);
  });

  test('uses IMDb when MAL is unavailable', () {
    final ratings = AnimeDetailsRatings.fromItem(
      _item(
        imdbId: 'tt0283754',
        syncData: const <String, String>{
          'awScore': '8.37',
          'awImdbScore': '7.4',
        },
      ),
    );
    expect(ratings.externalSource, ExternalRatingSource.imdb);
    expect(ratings.showExternalColumn, isTrue);
    expect(ratings.showImdbColumn, isTrue);
    expect(ratings.showMalColumn, isFalse);
    expect(ratings.externalScore, 7.4);
    expect(ratings.displayedExternalScoringUsers, isNull);
  });

  test('MAL takes priority when MAL and IMDb ratings both exist', () {
    final ratings = AnimeDetailsRatings.fromItem(
      _item(
        imdbId: 'tt0409591',
        syncData: const <String, String>{
          'malId': '20',
          'awMalScore': '8.73',
          'awMalScoringUsers': '668508',
          'awImdbScore': '7.8',
        },
      ),
    );
    expect(ratings.externalSource, ExternalRatingSource.mal);
    expect(ratings.showMalColumn, isTrue);
    expect(ratings.showImdbColumn, isFalse);
    expect(ratings.externalScore, 8.73);
    expect(ratings.displayedExternalScoringUsers, 668508);
  });

  test('unaired titles disable rating and zero MAL scoring users', () {
    final ratings = AnimeDetailsRatings.fromItem(
      _item(
        status: ShowStatus.upcoming,
        syncData: const <String, String>{
          'awState': 'لم يتم بثه بعد',
          'malId': '20',
          'awMalScore': '0.00',
          'awMalScoringUsers': '1234',
        },
      ),
    );
    expect(ratings.isUnaired, isTrue);
    expect(ratings.canRate, isFalse);
    expect(ratings.malMean, isNull);
  });

  test('unaired zeros displayed MAL scoring users when a mean exists', () {
    final ratings = AnimeDetailsRatings.fromItem(
      _item(
        status: ShowStatus.upcoming,
        syncData: const <String, String>{
          'awState': 'لم يتم بثه بعد',
          'malId': '20',
          'awMalScore': '6.2',
          'awMalScoringUsers': '1234',
        },
      ),
    );
    expect(ratings.showMalColumn, isTrue);
    expect(ratings.displayedMalScoringUsers, 0);
    expect(ratings.canRate, isFalse);
  });

  test('formats scores without trailing zeros', () {
    expect(formatRatingScore(9.1), '9.1');
    expect(formatRatingScore(8.73), '8.73');
    expect(formatRatingScore(7.0), '7');
  });

  test('hero rating state loads and renders the saved score for anime and manga', () {
    final anime = File(
      'lib/features/details/presentation/details_screen.dart',
    ).readAsStringSync();
    final manga = File(
      'lib/features/manga/presentation/manga_details_screen.dart',
    ).readAsStringSync();

    expect(anime, contains('loadAnimeUserRating'));
    expect(anime, contains("ratingCaption: _userRating == null ? null : '\${_userRating!}/10'"));
    expect(anime, contains('Icons.star_rounded'));
    expect(manga, contains('loadMangaUserRating'));
    expect(manga, contains("ratingCaption: _userRating == null ? null : '\${_userRating!}/10'"));
    expect(manga, contains('Icons.star_rounded'));
  });

  test('review target points at anime_list/{id}/reviews', () {
    final target = animeWitcherAnimeReviewTarget(_item());
    expect(target, isNotNull);
    expect(target!.collectionPath, 'anime_list/naruto/reviews');
    expect(target.isReviews, isTrue);
    expect(
      animeWitcherAnimeRatingPath('naruto', 'user-doc'),
      'anime_list/naruto/ratings/user-doc',
    );
  });
}
