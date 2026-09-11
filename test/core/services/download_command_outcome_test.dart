import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('downloadCommandOutcomeForJobState', () {
    test('maps active pipeline stages and queue distinctly', () {
      for (final state in [
        DownloadJobState.starting,
        DownloadJobState.running,
        DownloadJobState.assembling,
        DownloadJobState.verifying,
      ]) {
        expect(
          downloadCommandOutcomeForJobState(state),
          DownloadCommandOutcome.running,
        );
      }
      expect(
        downloadCommandOutcomeForJobState(DownloadJobState.queued),
        DownloadCommandOutcome.queued,
      );
    });

    test(
      'keeps transient failure, ownership settlement and pause distinct',
      () {
        for (final state in [
          DownloadJobState.retryWaiting,
          DownloadJobState.interrupted,
        ]) {
          expect(
            downloadCommandOutcomeForJobState(state),
            DownloadCommandOutcome.recoverableFailure,
          );
        }
        expect(
          downloadCommandOutcomeForJobState(DownloadJobState.pausing),
          DownloadCommandOutcome.settlingOwnership,
        );
        expect(
          downloadCommandOutcomeForJobState(DownloadJobState.pausedByUser),
          DownloadCommandOutcome.paused,
        );
      },
    );

    test('maps terminal, complete, orphaned and absent state explicitly', () {
      expect(
        downloadCommandOutcomeForJobState(DownloadJobState.completed),
        DownloadCommandOutcome.alreadyComplete,
      );
      expect(
        downloadCommandOutcomeForJobState(DownloadJobState.canceled),
        DownloadCommandOutcome.terminal,
      );
      expect(
        downloadCommandOutcomeForJobState(DownloadJobState.orphaned),
        DownloadCommandOutcome.missingState,
      );
      expect(
        downloadCommandOutcomeForJobState(null),
        DownloadCommandOutcome.missingState,
      );
    });
  });
}
