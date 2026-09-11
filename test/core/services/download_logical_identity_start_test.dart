import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DM-24 start/adoption logical identity', () {
    test('fresh start computes, queries and persists canonical logical id', () {
      final service = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();

      final start = service.indexOf(
        'Future<DownloadCommandOutcome> startDownloadOutcome({',
      );
      final complete = service.indexOf(
        'Future<List<TaskRecord>> _completeRecordsForEpisode(',
        start,
      );
      expect(start, greaterThanOrEqualTo(0));
      expect(complete, greaterThan(start));
      final body = service.substring(start, complete);

      expect(body, contains('DownloadLogicalIdentity.fromMedia'));
      expect(body, contains('_jobStore.allForLogicalId(logicalId)'));
      expect(body, contains('logicalId: logicalId'));
      expect(body, contains('saveDownloadMetadata('));
    });

    test('logical-id lookup occurs before tracking-url legacy fallback', () {
      final service = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final start = service.indexOf(
        'Future<DownloadCommandOutcome> startDownloadOutcome({',
      );
      final logicalLookup = service.indexOf(
        '_jobStore.allForLogicalId(logicalId)',
        start,
      );
      final legacyComment = service.indexOf(
        'Pre-logical-identity migration fallback',
        start,
      );

      expect(logicalLookup, greaterThan(start));
      expect(legacyComment, greaterThan(logicalLookup));
    });

    test('legacy adoption migrates reconstructable identity before URL fallback', () {
      final service = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final start = service.indexOf(
        'Future<DownloadCommandOutcome> startDownloadOutcome({',
      );
      final complete = service.indexOf(
        'Future<List<TaskRecord>> _completeRecordsForEpisode(',
        start,
      );
      final body = service.substring(start, complete);

      final allJobs = body.indexOf('final allJobs = await _jobStore.all()');
      final reconstructed = body.indexOf('logicalDownloadIdFromMetadata(metadata)');
      final legacyFallback = body.indexOf('Pre-logical-identity migration fallback');
      expect(allJobs, greaterThanOrEqualTo(0));
      expect(reconstructed, greaterThan(allJobs));
      expect(legacyFallback, greaterThan(reconstructed));
      expect(body, contains('if (candidateLogicalId != logicalId) continue;'));
      expect(body, contains('logicalId: logicalId'));
    });

    test('known different logical ids cannot collapse through tracking URL', () {
      final service = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final start = service.indexOf(
        'Future<DownloadCommandOutcome> startDownloadOutcome({',
      );
      final complete = service.indexOf(
        'Future<List<TaskRecord>> _completeRecordsForEpisode(',
        start,
      );
      final body = service.substring(start, complete);
      final fallback = body.lastIndexOf('Pre-logical-identity migration fallback');
      expect(fallback, greaterThanOrEqualTo(0));
      final fallbackBody = body.substring(fallback);

      final identityFence = fallbackBody.indexOf(
        'if (candidateLogicalId != null)',
      );
      final urlMatch = fallbackBody.indexOf(
        'if (candidateTracking == (trackingUrl ?? url))',
      );
      expect(identityFence, greaterThanOrEqualTo(0));
      expect(urlMatch, greaterThan(identityFence));
      expect(
        fallbackBody.substring(identityFence, urlMatch),
        contains('if (candidateLogicalId != logicalId) continue;'),
      );
    });

    test('complete-record matching prefers canonical identity over filename', () {
      final service = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final method = service.indexOf(
        'Future<List<TaskRecord>> _completeRecordsForEpisode(',
      );
      final next = service.indexOf('Future<void> _dropCompleteRecords(', method);
      expect(method, greaterThanOrEqualTo(0));
      expect(next, greaterThan(method));
      final body = service.substring(method, next);

      expect(body, contains('logicalDownloadIdFromMetadata'));
      expect(body, contains('logicalId'));
      expect(body, contains('Pre-logical-identity migration fallback'));
    });
  });
}
