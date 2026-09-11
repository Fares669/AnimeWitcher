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
  });
}
