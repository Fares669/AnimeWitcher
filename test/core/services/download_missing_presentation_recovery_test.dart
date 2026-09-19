
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

      });
}
