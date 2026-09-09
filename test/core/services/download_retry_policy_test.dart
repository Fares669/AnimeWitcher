import 'package:animewitcher/core/services/download_retry_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retryable HTTP statuses use exponential backoff', () {
    for (final status in [408, 425, 429, 500, 503, 599]) {
      final decision = planDownloadFailure(
        statusCode: status,
        retryIndex: 2,
        jitterUnit: 0.5,
      );
      expect(decision.action, DownloadFailureAction.retry, reason: '$status');
      expect(decision.delay, const Duration(seconds: 1));
    }
  });

  test('Retry-After overrides exponential delay and is capped', () {
    expect(
      planDownloadFailure(statusCode: 429, retryAfter: '7').delay,
      const Duration(seconds: 7),
    );
    expect(
      planDownloadFailure(statusCode: 503, retryAfter: '300').delay,
      kDownloadRetryMaxDelay,
    );
  });

  test('jitter spreads retry waves around the base delay', () {
    final low = downloadRetryDelay(retryIndex: 1, jitterUnit: 0);
    final middle = downloadRetryDelay(retryIndex: 1, jitterUnit: 0.5);
    final high = downloadRetryDelay(retryIndex: 1, jitterUnit: 1);
    expect(low, lessThan(middle));
    expect(middle, lessThan(high));
  });

  test('expired signed URLs refresh instead of retrying from zero', () {
    for (final status in [401, 403, 404]) {
      expect(
        planDownloadFailure(statusCode: status, canRefreshUrl: true).action,
        DownloadFailureAction.refreshUrl,
        reason: '$status',
      );
    }
    expect(
      planDownloadFailure(statusCode: 403, canRefreshUrl: false).action,
      DownloadFailureAction.park,
    );
  });

  test('416 reconciles the durable range before any network retry', () {
    expect(
      planDownloadFailure(statusCode: 416, canRefreshUrl: true).action,
      DownloadFailureAction.reconcileRange,
    );
  });

  test('connection failure is retryable without an HTTP status', () {
    final decision = planDownloadFailure(
      connectionFailure: true,
      retryIndex: 0,
      jitterUnit: 0.5,
    );
    expect(decision.action, DownloadFailureAction.retry);
    expect(decision.delay, kDownloadRetryBaseDelay);
  });

  test('disk full stops explicitly and wins over retryable status', () {
    expect(
      planDownloadFailure(statusCode: 503, noSpaceLeft: true).action,
      DownloadFailureAction.stopNoSpace,
    );
  });

  test('permanent unrelated HTTP errors park the episode', () {
    expect(
      planDownloadFailure(statusCode: 400, canRefreshUrl: true).action,
      DownloadFailureAction.park,
    );
  });
}
