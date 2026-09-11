import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/utils/download_cleanup.dart';

void main() {
  group('DM-14 canonical download containment regressions', () {
    test('lookalike download roots are not treated as app-owned', () {
      expect(
        pathIsInsideAppDownloads(
          '/tmp/AnimeWitcher/Downloads-Backup/unknown-user-file.mp4',
        ),
        isFalse,
      );
      expect(
        pathIsInsideAppDownloads(
          '/tmp/PrefixAnimeWitcher/Downloads/user-file.mp4',
        ),
        isFalse,
      );
    });

    test('dot-dot escape is not treated as contained', () {
      expect(
        pathIsInsideAppDownloads(
          '/tmp/AnimeWitcher/Downloads/Series/../../outside/user-file.mp4',
        ),
        isFalse,
      );
    });

    test('mixed separators cannot disguise a dot-dot escape', () {
      expect(
        pathIsInsideAppDownloads(
          r'C:\Users\me\AnimeWitcher\Downloads\Series\..\..\outside\user-file.mp4',
        ),
        isFalse,
      );
    });
  });
}
