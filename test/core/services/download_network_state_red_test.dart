import 'package:animewitcher/core/services/download_retry_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DM-09 network interruption classification regressions', () {
    test('offline interruption is not collapsed into server retry backoff', () {
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

      expect(
        offline.action,
        isNot(serverBusy.action),
        reason:
            'network-unavailable must project waitingForNetwork, while 5xx '
            'uses server retry/backoff',
      );
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
}
