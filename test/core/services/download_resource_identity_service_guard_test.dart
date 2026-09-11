import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DM-06 service resource identity', () {
    test('fresh jobs persist remote validator-bearing fingerprint', () {
      final source = File('lib/core/services/download_service.dart').readAsStringSync();
      final start = source.indexOf('Future<DownloadCommandOutcome> startDownloadOutcome({');
      final complete = source.indexOf('Future<List<TaskRecord>> _completeRecordsForEpisode(', start);
      final body = source.substring(start, complete);

      expect(body, contains('final remoteFingerprint = await _probeResourceFingerprint('));
      expect(body, contains('fingerprint: resourceFingerprint'));
      expect(body, contains('remoteFingerprint?.expectedBytes'));
    });

    test('native final expected size never comes from observed file length', () {
      final source = File('lib/core/services/download_service.dart').readAsStringSync();
      final start = source.indexOf('Future<void> _persistCompletedFilePath(Task task)');
      final end = source.indexOf('Future<String> getDownloadPath(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);
      final knownSizeStart = body.indexOf('final expectedBytes = knownDownloadSize');
      final ifTask = body.indexOf('if (task is DownloadTask)', knownSizeStart);
      expect(knownSizeStart, greaterThanOrEqualTo(0));
      expect(ifTask, greaterThan(knownSizeStart));
      final expectedBlock = body.substring(knownSizeStart, ifTask);

      expect(expectedBlock, isNot(contains('fileBytes,')));
      expect(expectedBlock, contains('job?.expectedBytes'));
      expect(expectedBlock, contains('currentFingerprint?.expectedBytes'));
      expect(body, contains('downloadCompletionEvidenceMatches('));
      expect(body, contains('verifyExistingPrefix('));
    });

    test('exact-size recovery proves prefix and fingerprint before complete', () {
      final source = File('lib/core/services/download_service.dart').readAsStringSync();
      final start = source.indexOf('Future<bool> _resumeUsingPartialFile(');
      final end = source.indexOf('Future<ParallelDownloadTask?> _parallelParentForInternalPart(', start);
      final body = source.substring(start, end);
      final exact = body.indexOf('if (expectedBytes > 0 && existingBytes == expectedBytes)');
      final checkpoint = body.indexOf('state: DownloadJobState.completed', exact);
      expect(exact, greaterThanOrEqualTo(0));
      expect(checkpoint, greaterThan(exact));
      final proofBody = body.substring(exact, checkpoint);

      expect(proofBody, contains('_probeResourceFingerprint('));
      expect(proofBody, contains('verifyExistingPrefix('));
      expect(proofBody, contains('downloadCompletionEvidenceMatches('));
    });

    test('source refresh fences changed validators but permits delivery URL rotation', () {
      final source = File('lib/core/services/download_service.dart').readAsStringSync();
      final start = source.indexOf('Future<({DownloadTask task, bool refreshed})> _refreshTaskBeforeResume(');
      final end = source.indexOf('Future<List<Task>> _liveTransferTasks()', start);
      final body = source.substring(start, end);

      expect(body, contains('authoritativeFingerprint.compatibleWith(currentFingerprint)'));
      expect(body, contains('authoritativeFingerprint.compatibleWith(refreshedFingerprint)'));
      expect(body, contains('!refreshedIdentityMatches'));
      expect(body, contains('fingerprint: fingerprintWithExpectedBytes('));
    });
  });
}
