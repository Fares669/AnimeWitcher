import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_service.dart';
import 'package:animewitcher/core/services/download_transport.dart';
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

  group('DM-03 command x state x ownership matrix', () {
    test('resume attaches only when durable state is absent and owner is live', () {
      expect(
        resolveResumeCommandOutcome(
          state: null,
          ownership: DownloadRuntimeOwnership.owned,
        ),
        DownloadCommandOutcome.attached,
      );
      for (final ownership in [
        DownloadRuntimeOwnership.settling,
        DownloadRuntimeOwnership.unknown,
      ]) {
        expect(
          resolveResumeCommandOutcome(state: null, ownership: ownership),
          DownloadCommandOutcome.settlingOwnership,
        );
      }
      expect(
        resolveResumeCommandOutcome(
          state: null,
          ownership: DownloadRuntimeOwnership.notOwned,
        ),
        DownloadCommandOutcome.missingState,
      );
    });

    test('JobStore authority wins over stale ownership for pause/resume', () {
      for (final ownership in DownloadRuntimeOwnership.values) {
        expect(
          resolvePauseCommandOutcome(
            state: DownloadJobState.pausedByUser,
            ownership: ownership,
          ),
          DownloadCommandOutcome.paused,
        );
        expect(
          resolveResumeCommandOutcome(
            state: DownloadJobState.retryWaiting,
            ownership: ownership,
          ),
          DownloadCommandOutcome.recoverableFailure,
        );
        expect(
          resolveResumeCommandOutcome(
            state: DownloadJobState.completed,
            ownership: ownership,
          ),
          DownloadCommandOutcome.alreadyComplete,
        );
      }
    });

    test('pause fails closed when state is missing but ownership is uncertain', () {
      for (final ownership in [
        DownloadRuntimeOwnership.owned,
        DownloadRuntimeOwnership.settling,
        DownloadRuntimeOwnership.unknown,
      ]) {
        expect(
          resolvePauseCommandOutcome(state: null, ownership: ownership),
          DownloadCommandOutcome.settlingOwnership,
        );
      }
      expect(
        resolvePauseCommandOutcome(
          state: null,
          ownership: DownloadRuntimeOwnership.notOwned,
        ),
        DownloadCommandOutcome.missingState,
      );
    });

    test('cancel is terminal only after ownership release', () {
      for (final ownership in [
        DownloadRuntimeOwnership.owned,
        DownloadRuntimeOwnership.settling,
        DownloadRuntimeOwnership.unknown,
      ]) {
        expect(
          resolveCancelCommandOutcome(
            state: DownloadJobState.canceled,
            ownership: ownership,
          ),
          DownloadCommandOutcome.settlingOwnership,
        );
      }
      expect(
        resolveCancelCommandOutcome(
          state: null,
          ownership: DownloadRuntimeOwnership.notOwned,
        ),
        DownloadCommandOutcome.terminal,
      );
      expect(
        resolveCancelCommandOutcome(
          state: DownloadJobState.canceled,
          ownership: DownloadRuntimeOwnership.notOwned,
        ),
        DownloadCommandOutcome.terminal,
      );
      expect(
        resolveCancelCommandOutcome(
          state: DownloadJobState.interrupted,
          ownership: DownloadRuntimeOwnership.notOwned,
        ),
        DownloadCommandOutcome.recoverableFailure,
      );
    });
  });

}
