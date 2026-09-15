import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_job_store.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _v7Row({
  String state = 'pausedByUser',
  bool userPaused = true,
}) => <String, Object?>{
  'schemaVersion': 7,
  'taskId': 'episode-v7',
  'logicalId': 'anime:42:episode:7',
  'trackingUrl': 'https://example.test/watch/42/7',
  'state': state,
  'generation': 4,
  'durableBytes': 512,
  'durableByteProvenance': 'exactDisk',
  'expectedBytes': 4096,
  'userPaused': userPaused,
  'queueWaiting': false,
  'updatedAtMillis': 1_700_000_000_000,
  'fingerprint': <String, Object?>{
    'strongEtag': '"v7-resource"',
    'lastModified': 'Tue, 15 Sep 2026 12:00:00 GMT',
    'expectedBytes': 4096,
    'finalUrl': 'https://cdn.example.test/video.mp4?token=old',
  },
};

void main() {
  group('PR #231 schema v7 compatibility', () {
    test('preserves user pause intent, logical identity, and fingerprint', () {
      final decoded = DownloadJobRecord.fromJson(_v7Row());

      expect(decoded, isNotNull);
      expect(decoded!.taskId, 'episode-v7');
      expect(decoded.logicalId, 'anime:42:episode:7');
      expect(decoded.state, DownloadJobState.pausedByUser);
      expect(decoded.userPaused, isTrue);
      expect(decoded.generation, 4);
      expect(decoded.durableBytes, 512);
      expect(
        decoded.durableByteProvenance,
        DownloadDurableByteProvenance.exactDisk,
      );
      expect(decoded.expectedBytes, 4096);
      expect(decoded.fingerprint?.strongEtag, '"v7-resource"');
      expect(
        decoded.fingerprint?.lastModified,
        'Tue, 15 Sep 2026 12:00:00 GMT',
      );
      expect(decoded.fingerprint?.expectedBytes, 4096);
      expect(
        decoded.fingerprint?.finalUrl,
        'https://cdn.example.test/video.mp4?token=old',
      );
    });

    test('preserves durable delete/cancel intent', () {
      final decoded = DownloadJobRecord.fromJson(
        _v7Row(state: 'canceled', userPaused: false),
      );

      expect(decoded, isNotNull);
      expect(decoded!.state, DownloadJobState.canceled);
      expect(decoded.userPaused, isFalse);
      expect(decoded.logicalId, 'anime:42:episode:7');
      expect(decoded.fingerprint?.strongEtag, '"v7-resource"');
    });
  });
}
