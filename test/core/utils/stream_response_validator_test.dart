import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/utils/stream_response_validator.dart';

void main() {
  group('isLikelyPlayableHttpResponse', () {
    test('accepts a binary video response', () {
      expect(
        isLikelyPlayableHttpResponse(
          uri: Uri.parse('https://cdn.example/video.mp4'),
          statusCode: 206,
          contentType: 'application/octet-stream',
          bodyPrefix: const <int>[0, 0, 0, 24, 102, 116, 121, 112],
        ),
        isTrue,
      );
    });

    test('rejects an HTML download or error page with status 200', () {
      expect(
        isLikelyPlayableHttpResponse(
          uri: Uri.parse('https://www.mediafire.com/file_premium/abc/file'),
          statusCode: 200,
          contentType: 'text/html; charset=UTF-8',
          bodyPrefix: utf8.encode('<html><head><title>Site Unavailable</title>'),
        ),
        isFalse,
      );
    });

    test('detects HTML even when the server omits its content type', () {
      expect(
        isLikelyPlayableHttpResponse(
          uri: Uri.parse('https://cdn.example/video.mp4'),
          statusCode: 200,
          bodyPrefix: utf8.encode('<!doctype html><html>blocked</html>'),
        ),
        isFalse,
      );
    });

    test('allows textual adaptive manifests', () {
      expect(
        isLikelyPlayableHttpResponse(
          uri: Uri.parse('https://cdn.example/master.m3u8'),
          statusCode: 200,
          contentType: 'text/plain',
          bodyPrefix: utf8.encode('#EXTM3U'),
        ),
        isTrue,
      );
    });
  });
}
