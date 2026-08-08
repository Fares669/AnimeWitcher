import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/providers/mediafire_utils.dart';

void main() {
  group('mediaFirePageRequestUrl', () {
    test('preserves AnimeWitcher MF2 premium links exactly', () {
      const url =
          'https://www.mediafire.com/file_premium/abc123/video%25282%2529.mp4/file';

      expect(mediaFirePageRequestUrl(url), url);
    });

    test('does not change normal MediaFire links', () {
      const url = 'https://www.mediafire.com/file/abc123/video.mp4/file';

      expect(mediaFirePageRequestUrl(url), url);
    });

    test('adds a scheme without changing the route', () {
      const url = 'www.mediafire.com/file_premium/abc123/video.mp4/file';

      expect(mediaFirePageRequestUrl(url), 'https://$url');
    });

    test('resolves a root-relative premium route against MediaFire', () {
      const path = '/file_premium/abc123/video.mp4/file';

      expect(
        mediaFirePageRequestUrl(path),
        'https://www.mediafire.com$path',
      );
    });
  });
}
