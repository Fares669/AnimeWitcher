import 'dart:io';

import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_retry_policy.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DM-09 network interruption classification regressions', () {
    test('offline interruption is a dedicated zero-delay network hold', () {
      final offline = planDownloadFailure(
        connectionFailure: true,
        retryIndex: 4,
        jitterUnit: 0.5,
      );
      final serverBusy = planDownloadFailure(
        statusCode: 503,
        retryIndex: 4,
        jitterUnit: 0.5,
      );

      expect(offline.action.name, 'waitForNetwork');
      expect(
        offline.delay,
        Duration.zero,
        reason:
            'offline time must not consume exponential server backoff; resume '
            'is driven by network availability instead',
      );
      expect(serverBusy.action, DownloadFailureAction.retry);
      expect(serverBusy.delay, greaterThan(Duration.zero));
    });

    test('429 remains server backoff and honors Retry-After', () {
      final rateLimited = planDownloadFailure(
        statusCode: 429,
        retryIndex: 0,
        retryAfter: '7',
      );

      expect(rateLimited.action, DownloadFailureAction.retry);
      expect(rateLimited.delay, const Duration(seconds: 7));
    });

    test('non-network terminal HTTP failure stays parked', () {
      final badRequest = planDownloadFailure(statusCode: 400);
      expect(badRequest.action, DownloadFailureAction.park);
      expect(badRequest.delay, Duration.zero);
    });
  });

  group('DM-09 durable logical network hold', () {
    test('waitingForNetwork is distinct from retry backoff and user pause', () {
      final waiting = DownloadJobState.values.byName('waitingForNetwork');

      expect(waiting, isNot(DownloadJobState.retryWaiting));
      expect(waiting, isNot(DownloadJobState.pausedByUser));
      expect(downloadJobHasUserPauseIntent(waiting), isFalse);
      expect(downloadJobIsTerminal(waiting), isFalse);
      expect(downloadJobOccupiesSlot(waiting), isFalse);
      expect(downloadJobTaskStatus(waiting), TaskStatus.waitingToRetry);
      expect(downloadJobDisplayStatus(waiting), TaskStatus.waitingToRetry);
    });
  });

  group('DM-09 cross-transport ownership', () {
    test(
      'service observes connectivity and reconciles held jobs through fencing',
      () {
        final source = File('lib/core/services/download_service.dart')
            .readAsStringSync();
        expect(source, contains('connectivity_plus'));
        expect(source, contains('onConnectivityChanged'));
        expect(source, contains('DownloadJobState.waitingForNetwork'));
        expect(source, contains('_resumeNetworkHeldDownloads'));
        expect(source, contains('_jobStore.beginOperation('));
      },
    );

    test('iOS offline errors do not consume background retry budget', () {
      final source = File('ios/Runner/DownloadNativeWaitingQueue.swift')
          .readAsStringSync();
      expect(
        source,
        contains('isNetworkUnavailableBackgroundTransportErrorCode'),
      );
      expect(source, contains('background.networkHold'));

      final retryStart = source.indexOf(
        'static func retryBackgroundTransferIfNeeded(',
      );
      final hookStart = source.indexOf(
        'private static func hookComplete(',
        retryStart,
      );
      expect(retryStart, greaterThanOrEqualTo(0));
      expect(hookStart, greaterThan(retryStart));
      final retryBody = source.substring(retryStart, hookStart);
      final offlineGate = retryBody.indexOf(
        'isNetworkUnavailableBackgroundTransportErrorCode',
      );
      final budgetIncrement = retryBody.indexOf('retry.totalRetries += 1');
      expect(offlineGate, greaterThanOrEqualTo(0));
      expect(budgetIncrement, greaterThan(offlineGate));
      expect(
        retryBody.substring(offlineGate, budgetIncrement),
        contains('return'),
        reason: 'offline must exit before retry counters are incremented',
      );
    });
  });
}
