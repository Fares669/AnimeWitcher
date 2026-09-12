import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DM-24 overlay/native logical identity', () {
    test('overlay entry prefers persisted logical id over mutable executor keys', () {
      final source = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final start = source.indexOf('Future<DownloadOverlaySession> _planSessionOverlay(');
      final end = source.indexOf('Future<void> _syncSessionOverlay(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(body, contains('logicalDownloadIdFromMetadata'));
      expect(body, contains("job?.logicalId"));
      expect(body, contains('episodeKey: logicalId'));
    });

    test('native waiter payload persists canonical logical identity', () {
      final source = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final start = source.indexOf(
        'Future<Map<String, Object>> _waitingPayloadPreservingBytes(',
      );
      final end = source.indexOf('_savedProgressFor(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(body, contains('logicalDownloadIdFromMetadata'));
      expect(body, contains("payload['logicalId'] = logicalId"));
    });

    test('legacy overlay key fallback is explicitly migration-only', () {
      final source = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final method = source.indexOf('String _overlayEpisodeKeyFromParts({');
      expect(method, greaterThanOrEqualTo(0));
      final before = source.substring(method - 200 < 0 ? 0 : method - 200, method);
      expect(before, contains('Pre-logical-identity migration fallback'));
    });
  });
}
