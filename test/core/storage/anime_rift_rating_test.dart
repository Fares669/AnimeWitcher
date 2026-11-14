import 'package:animewitcher/core/storage/anime_rift_rating.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Rift rating preserves separate fractional scores from account interactions', () {
    final rating = AnimeRiftRating.fromServer({
      'interactions': {
        'general_rating': 8.5,
        'story_rating': 9,
        'characters_rating': 7.5,
        'animation_rating': 8,
        'music_rating': 6,
      },
    });
    expect(rating, isNotNull);
    // AnimeRift's native editor derives the general score from these four.
    expect(rating!.general, (9 + 7.5 + 8 + 6) / 4);
    expect(rating.characters, 7.5);
    expect(rating.toJson()['music_rating'], 6.0);
    expect(
      AnimeRiftRating.fromMap({...rating.toJson(), 'story_rating': -1}),
      isNull,
    );
    expect(
      AnimeRiftRating.fromServer({
        'interactions': {'general_rating': 8},
      }),
      isNull,
    );
    expect(
      AnimeRiftRating.fromMap({
        'story_rating': 8,
        'characters_rating': 7,
        'animation_rating': 9,
        'music_rating': 6,
        'general_rating': 1, // Old server values cannot override the mean.
      })?.general,
      7.5,
    );
    expect(
      AnimeRiftRating.fromMap({
        'story_rating': 8,
        'characters_rating': 7,
        'animation_rating': 9,
        'music_rating': 6,
      })?.general,
      7.5,
    );
  });
}
