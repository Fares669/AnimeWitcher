import 'dart:io';

import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:background_downloader/background_downloader.dart';
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

    test('UI projection is derived from JobState, not executor pause flags', () {
      expect(downloadJobDisplayStatus(DownloadJobState.queued), TaskStatus.enqueued);
      expect(downloadJobDisplayStatus(DownloadJobState.starting), TaskStatus.enqueued);
      expect(downloadJobDisplayStatus(DownloadJobState.running), TaskStatus.running);
      expect(
        downloadJobDisplayStatus(DownloadJobState.retryWaiting),
        TaskStatus.waitingToRetry,
      );
      expect(downloadJobDisplayStatus(DownloadJobState.pausedByUser), TaskStatus.paused);
      expect(downloadJobDisplayStatus(DownloadJobState.interrupted), TaskStatus.paused);
      expect(downloadJobDisplayStatus(DownloadJobState.completed), TaskStatus.complete);
      expect(downloadJobDisplayStatus(DownloadJobState.canceled), TaskStatus.canceled);
    });

    test('service queue accounting consults JobStore before legacy replicas', () {
      final source = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();

      final occupiedStart = source.indexOf(
        'Future<int> _occupiedSlotCount(List<TaskRecord> records) async',
      );
      final queueStart = source.indexOf(
        'Future<List<DownloadQueueEntry>> _queueEntries(',
      );
      final syncStart = source.indexOf(
        'Future<void> _syncQueueToCapUnlocked()',
      );
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

    test('native waiting snapshot does not infer user pause from plugin paused', () {
      final source = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final start = source.indexOf('Future<void> _persistNativeWaitingSnapshot(');
      final end = source.indexOf('String? _notificationConfigJson(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(body, contains('final job = await _jobStore.get(task.taskId)'));
      expect(body, contains('downloadJobUserPaused(job.state)'));
      expect(body, contains('downloadJobQueueWaiting(job.state)'));
      expect(body, contains('Pre-JobStore migration fallback'));
      expect(
        body.indexOf('final job = await _jobStore.get(task.taskId)'),
        lessThan(body.indexOf('record.status == TaskStatus.paused')),
      );
    });

    test('session overlay status and waiting intent are JobState-first', () {
      final source = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final start = source.indexOf('Future<DownloadOverlaySession> _planSessionOverlay(');
      final end = source.indexOf('Future<void> _syncSessionOverlay(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(body, contains('final job = await _jobStore.get(record.task.taskId)'));
      expect(body, contains('downloadJobQueueWaiting(job.state)'));
      expect(body, contains('downloadJobOccupiesSlot(job.state)'));
      expect(body, contains('downloadJobDisplayStatus(job.state)'));
      expect(body, contains('Pre-JobStore migration fallback'));
    });

    test('payload-only session overlay rows still consult JobState', () {
      final source = File(
        'lib/core/services/download_service.dart',
      ).readAsStringSync();
      final start = source.indexOf('Future<DownloadOverlaySession> _planSessionOverlay(');
      final end = source.indexOf('Future<void> _syncSessionOverlay(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);
      final waiterStart = body.indexOf('for (final payload in _waitingPayloads.entries)');
      expect(waiterStart, greaterThanOrEqualTo(0));
      final waiterBody = body.substring(waiterStart);

      expect(waiterBody, contains('final job = await _jobStore.get(payload.key)'));
      expect(
        waiterBody,
        contains('if (job != null && !downloadJobQueueWaiting(job.state)) continue;'),
      );
      expect(waiterBody, contains('downloadJobDisplayStatus(job.state)'));
      expect(waiterBody, contains('downloadJobQueueWaiting(job.state)'));
    });
  });
}
