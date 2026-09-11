import 'dart:async';

import 'package:animewitcher/core/services/download_service_readiness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'concurrent callers join the exact same initialization Future',
    () async {
      final barrier = DownloadServiceReadinessBarrier();
      final release = Completer<void>();
      var attempts = 0;

      Future<void> initialize() {
        attempts += 1;
        return release.future;
      }

      final first = barrier.ensureReady(initialize);
      final second = barrier.ensureReady(initialize);
      final third = barrier.ensureReady(initialize);

      expect(identical(first, second), isTrue);
      expect(identical(first, third), isTrue);
      expect(attempts, 1);
      expect(barrier.state, DownloadServiceReadinessState.initializing);

      release.complete();
      await Future.wait([first, second, third]);

      expect(barrier.state, DownloadServiceReadinessState.ready);
      await barrier.ensureReady(initialize);
      expect(attempts, 1);
    },
  );

  test(
    'failed initialization is typed, retryable, and next call retries',
    () async {
      final barrier = DownloadServiceReadinessBarrier();
      var attempts = 0;

      Future<void> initialize() async {
        attempts += 1;
        if (attempts == 1) throw StateError('storage unavailable');
      }

      await expectLater(
        barrier.ensureReady(initialize),
        throwsA(
          isA<DownloadServiceUnavailableException>()
              .having(
                (error) => error.reason,
                'reason',
                DownloadServiceUnavailableReason.initializationFailed,
              )
              .having((error) => error.retryable, 'retryable', isTrue)
              .having((error) => error.cause, 'cause', isA<StateError>()),
        ),
      );
      expect(barrier.state, DownloadServiceReadinessState.idle);

      await barrier.ensureReady(initialize);
      expect(attempts, 2);
      expect(barrier.state, DownloadServiceReadinessState.ready);
    },
  );
}
