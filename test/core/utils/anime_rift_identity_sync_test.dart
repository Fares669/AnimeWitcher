import 'package:animewitcher/core/utils/anime_rift_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only a stable Rift episode id can enter cloud progress journal', () {
    expect(
      animeRiftEpisodeIdForSync(
        'https://anime-rift.com/anime/show-1/episode/ep_2',
      ),
      'ep_2',
    );
    expect(
      animeRiftEpisodeIdForSync(
        'https://www.anime-rift.com/anime/show-1/episode/ep_2',
      ),
      'ep_2',
    );
    expect(animeRiftEpisodeIdForSync(null), isNull);
    for (final unsafe in <String>[
      'https://cdn.example.org/episode/ep_2?token=secret',
      'https://anime-rift.com/anime/show-1/episode/ep_2?token=secret',
      'https://anime-rift.com/anime/show-1/episode/ep_2#token',
      'http://anime-rift.com/anime/show-1/episode/ep_2',
      'https://attacker@anime-rift.com/anime/show-1/episode/ep_2',
      'https://anime-rift.com/anime/show-1/episode/ep_2/more',
      'https://anime-rift.com/anime/show-1/episode/%2F',
    ]) {
      expect(animeRiftEpisodeIdForSync(unsafe), isNull, reason: unsafe);
    }
  });
}
