import 'dart:io';

import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DM-05 queue/slot lifecycle authority', () {
    test('logical states deterministically project queue and pause intent', () {
      expect(downloadJobQueueWaiting(DownloadJobState.queued), isTrue);
      expect(downloadJobUserPaused(DownloadJobState.queued), isFalse);

      expect(downloadJobUserPaused(DownloadJobState.pausedByUser), isTrue);
      expect(downloadJobQueueWaiting(DownloadJobState.pausedByUser), isFalse);

      for (final state in <DownloadJobState>[
        DownloadJobState.starting,
        DownloadJobState.running,
        DownloadJobState.retryWaiting,
        DownloadJobState.pausing,
        DownloadJobState.assembling,
        DownloadJobState.verifying,
      ]) {
        expect(
          downloadJobOccupiesSlot(state),
          isTrue,
          reason: '$state must reserve one logical episode slot',
        );
      }

      for (final state in <DownloadJobState>[
        DownloadJobState.queued,
        DownloadJobState.pausedByUser,
        DownloadJobState.interrupted,
        DownloadJobState.completed,
        DownloadJobState.canceled,
        DownloadJobState.orphaned,
      ]) {
        expect(
          downloadJobOccupiesSlot(state),
          isFalse,
          reason: '$state must not reserve a logical episode slot',
        );
      }
    });

    test('service queue accounting consults JobStore before legacy replicas', () {
      final source = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();

      final occupiedStart = source.indexOf(' _occupiedSlotCount(');
      final queueStart = source.indexOf(' _queueEntries(');
      final syncStart = source.indexOf(' _syncQueueToCapUnlocked(');
      expect(occupiedStart, greaterThanOrEqualTo(0));
      expect(queueStart, greaterThan(occupiedStart));
      expect(syncStart, greaterThan(queueStart));

      final occupiedBody = source.substring(occupiedStart, queueStart);
      final queueBody = source.substring(queueStart, syncStart);

      expect(occupiedBody, contains('_jobStore'));
      expect(occupiedBody, contains('downloadJobOccupiesSlot'));
      expect(queueBody, contains('_jobStore'));
      expect(queueBody, contains('downloadJobQueueWaiting'));
      expect(queueBody, contains('downloadJobUserPaused'));
    });
  });
}
