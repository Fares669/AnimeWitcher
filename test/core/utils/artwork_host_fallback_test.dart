import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    malArtworkUnreachable.value = false;
    applyArtworkFallbackEnabled(false);
  });

  const mal = 'https://cdn.myanimelist.net/images/anime/1244/138851.jpg';
  const aniList =
      'https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx21.jpg';

  test('a reachable CDN keeps the catalog order', () {
    expect(preferReachableArtwork(const [mal, aniList]), const [mal, aniList]);
  });

  test('a blocked CDN puts the AniList copy first without the setting', () {
    applyArtworkFallbackEnabled(false);
    malArtworkUnreachable.value = true;
    expect(preferReachableArtwork(const [mal, aniList]), const [aniList, mal]);
  });

  test('turning the lookup setting off does not forget the block', () {
    malArtworkUnreachable.value = true;
    applyArtworkFallbackEnabled(false);
    expect(malArtworkUnreachable.value, isTrue);
  });
}
