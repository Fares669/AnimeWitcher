import 'dart:io';

import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('missing presentation recovery', () {
    test('renderable metadata keeps normal recovery', () {
      expect(
        planMissingPresentationRecovery(
          hasPresentationMetadata: true,
          hasLiveOwnership: true,
          authoritativeState: DownloadJobState.running,
        ),
        DownloadMissingPresentationRecoveryDisposition.recover,
      );
    });

    test('missing metadata with a live writer must settle ownership first', () {
      expect(
        planMissingPresentationRecovery(
          hasPresentationMetadata: false,
          hasLiveOwnership: true,
          authoritativeState: DownloadJobState.running,
        ),
        DownloadMissingPresentationRecoveryDisposition.settleOwner,
        reason:
            'a native writer must not continue invisibly after its user-visible identity is lost',
      );
    });

    test('missing metadata without a writer becomes an explicit orphan', () {
      expect(
        planMissingPresentationRecovery(
          hasPresentationMetadata: false,
          hasLiveOwnership: false,
          authoritativeState: DownloadJobState.interrupted,
        ),
        DownloadMissingPresentationRecoveryDisposition.orphan,
      );
    });

    test('terminal tombstones are never reclassified or resurrected', () {
      for (final state in <DownloadJobState>[
        DownloadJobState.completed,
        DownloadJobState.canceled,
        DownloadJobState.orphaned,
      ]) {
        expect(
          planMissingPresentationRecovery(
            hasPresentationMetadata: false,
            hasLiveOwnership: true,
            authoritativeState: state,
          ),
          DownloadMissingPresentationRecoveryDisposition.preserveTerminal,
          reason: '$state',
        );
      }
    });

    test('startup handles missing presentation before normal recovery planning', () {
      final source = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final recoveryStart = source.indexOf(
        'Future<void> _recoverPersistedDownloads() async {',
      );
      final recordLoop = source.indexOf('for (final record in records)', recoveryStart);
      final stillNative = source.indexOf('final stillNative =', recordLoop);
      final presentationPlan = source.indexOf(
        'planMissingPresentationRecovery(',
        stillNative,
      );
      final normalPlan = source.indexOf(
        'planDownloadRecoveryWithJobAuthority(',
        stillNative,
      );

      expect(recoveryStart, greaterThanOrEqualTo(0));
      expect(recordLoop, greaterThan(recoveryStart));
      expect(stillNative, greaterThan(recordLoop));
      expect(presentationPlan, greaterThan(stillNative));
      expect(presentationPlan, lessThan(normalPlan));

      final guardedBlock = source.substring(presentationPlan, normalPlan);
      expect(guardedBlock, contains("metadata?['item'] is Map"));
      expect(
        guardedBlock,
        contains('DownloadMissingPresentationRecoveryDisposition.settleOwner'),
      );
      expect(guardedBlock, contains("'recovery.missingPresentationSettling'"));
      expect(guardedBlock, contains("'recovery.orphanedMissingPresentation'"));
      expect(guardedBlock, contains('await _pauseTransfer(task)'));
    });
  });
}
