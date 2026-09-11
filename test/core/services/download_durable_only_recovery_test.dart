import 'dart:io';

import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('durable-only inventory recovery disposition', () {
    test('missing presentation metadata becomes an explicit orphan', () {
      expect(
        planDurableOnlyRecoveryDisposition(
          hasPresentationMetadata: false,
          hasRecoverableTaskDescriptor: true,
        ),
        DownloadDurableOnlyRecoveryDisposition.orphan,
        reason:
            'a task snapshot can restart bytes but cannot reconstruct the user-visible anime/episode row',
      );
    });

    test('complete metadata plus a task descriptor remains recoverable', () {
      expect(
        planDurableOnlyRecoveryDisposition(
          hasPresentationMetadata: true,
          hasRecoverableTaskDescriptor: true,
        ),
        DownloadDurableOnlyRecoveryDisposition.recover,
      );
    });

    test('metadata without an executable task descriptor is orphaned', () {
      expect(
        planDurableOnlyRecoveryDisposition(
          hasPresentationMetadata: true,
          hasRecoverableTaskDescriptor: false,
        ),
        DownloadDurableOnlyRecoveryDisposition.orphan,
      );
    });

    test('startup gates JobStore-only recovery before rebuilding projection', () {
      final source = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final recoveryStart = source.indexOf(
        'Future<void> _recoverPersistedDownloads() async {',
      );
      final jobLoop = source.indexOf('for (final job in jobs)', recoveryStart);
      final disposition = source.indexOf(
        'planDurableOnlyRecoveryDisposition(',
        jobLoop,
      );
      final durableProjection = source.indexOf('durableRecords.add(', jobLoop);

      expect(recoveryStart, greaterThanOrEqualTo(0));
      expect(jobLoop, greaterThan(recoveryStart));
      expect(disposition, greaterThan(jobLoop));
      expect(disposition, lessThan(durableProjection));

      final guardedBlock = source.substring(disposition, durableProjection);
      expect(
        guardedBlock,
        contains('hasPresentationMetadata: metadata != null'),
      );
      expect(
        guardedBlock,
        contains('hasRecoverableTaskDescriptor: task != null'),
      );
      expect(
        guardedBlock,
        contains('DownloadDurableOnlyRecoveryDisposition.orphan'),
      );
      expect(
        guardedBlock,
        contains("'recovery.orphanedMissingPresentation'"),
      );
    });
  });
}
