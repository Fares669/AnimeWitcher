import 'package:animewitcher/features/skip/data/anime_id_mappings.dart';
import 'package:animewitcher/features/skip/data/intro_db_service.dart';
import 'package:animewitcher/features/skip/data/skip_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reading IntroDB v4 spans', () {
    test('takes intro, recap, credits and preview', () {
      // The shape the service actually answers with, milliseconds and all.
      final segments = IntroDbService.parseSegments({
        'tvdb_id': 465787,
        'intro': [
          {'start_ms': null, 'end_ms': 90069},
        ],
        'credits': [
          {'start_ms': 1460042, 'end_ms': 1550042},
        ],
        'preview': [
          {'start_ms': 1550394, 'end_ms': null},
        ],
      }, durationSec: 1560);

      expect(segments.length, 3);
      // A null start is the first frame.
      expect(segments.first.type, SkipType.intro);
      expect(segments.first.startTime, 0);
      expect(segments.first.endTime, closeTo(90.069, 0.001));
      // A null end runs to the end of the episode.
      expect(segments.last.endTime, 1560);
    });

    test('an open-ended span with no duration to close it is dropped', () {
      final segments = IntroDbService.parseSegments({
        'preview': [
          {'start_ms': 1550394, 'end_ms': null},
        ],
      });
      expect(segments, isEmpty);
    });

    test('a media-not-found answer is no segments', () {
      expect(
        IntroDbService.parseSegments({'error': 'media not found'}),
        isEmpty,
      );
      expect(IntroDbService.parseSegments(null), isEmpty);
    });
  });

  group('reading ani.zip mappings', () {
    test('takes the ids IntroDB and AniSkip need', () {
      final ids = AnimeIds.parse({
        'mappings': {
          'mal_id': 62048,
          'anilist_id': 196012,
          'thetvdb_id': 465787,
          'imdb_id': 'tt37577523',
          'themoviedb_id': '295999',
        },
      });

      expect(ids, isNotNull);
      expect(ids!.imdbId, 'tt37577523');
      // ani.zip gives this one as a string.
      expect(ids.tmdbId, 295999);
      expect(ids.tvdbId, 465787);
      expect(ids.aniListId, 196012);
    });

    test('an entry with no cross-ids is nothing to act on', () {
      expect(
        AnimeIds.parse({
          'mappings': {'mal_id': 1, 'notifymoe_id': null},
        }),
        isNull,
      );
      expect(AnimeIds.parse({'titles': <String, dynamic>{}}), isNull);
    });

    test('survives a round trip through storage', () {
      const ids = AnimeIds(imdbId: 'tt1', tmdbId: 2, tvdbId: 3, aniListId: 4);
      final restored = AnimeIds.fromJson(ids.toJson());
      expect(restored?.imdbId, 'tt1');
      expect(restored?.tmdbId, 2);
      expect(restored?.tvdbId, 3);
      expect(restored?.aniListId, 4);
    });
  });
}
