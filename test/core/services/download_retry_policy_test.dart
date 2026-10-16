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

  test('Retry-After overrides exponential delay without the local cap', () {
    expect(
      planDownloadFailure(statusCode: 429, retryAfter: '7').delay,
      const Duration(seconds: 7),
    );
    expect(
      planDownloadFailure(statusCode: 503, retryAfter: '300').delay,
      const Duration(seconds: 300),
    );
  });

  test('jitter spreads retry waves around the base delay', () {
    final low = downloadRetryDelay(retryIndex: 1, jitterUnit: 0);
    final middle = downloadRetryDelay(retryIndex: 1, jitterUnit: 0.5);
    final high = downloadRetryDelay(retryIndex: 1, jitterUnit: 1);
    expect(low, lessThan(middle));
    expect(middle, lessThan(high));
  });

  test('default jitter changes delays while staying within bounds', () {
    final delays = List.generate(
      32,
      (_) => downloadRetryDelay(retryIndex: 1).inMicroseconds,
    );
    expect(delays.toSet().length, greaterThan(1));
    expect(delays, everyElement(inInclusiveRange(400000, 600000)));
  });

  test('exponential backoff reaches the local maximum', () {
    expect(
      downloadRetryDelay(retryIndex: 7, jitterUnit: 0.5),
      kDownloadRetryMaxDelay,
    );
    expect(
      downloadRetryDelay(retryIndex: 1000000, jitterUnit: 0),
      const Duration(seconds: 24),
    );
    expect(
      downloadRetryDelay(retryIndex: 1000000, jitterUnit: 1),
      kDownloadRetryMaxDelay,
    );
  });

  test('negative retry indexes use the first backoff interval', () {
    expect(
      downloadRetryDelay(retryIndex: -1, jitterUnit: 0.5),
      kDownloadRetryBaseDelay,
    );
  });

  test('explicit jitter remains bounded', () {
    expect(
      downloadRetryDelay(retryIndex: 1, jitterUnit: -1),
      const Duration(milliseconds: 400),
    );
    expect(
      downloadRetryDelay(retryIndex: 1, jitterUnit: 2),
      const Duration(milliseconds: 600),
    );
  });

  test('Retry-After seconds ignore local jitter and retain zero', () {
    for (final jitter in [0.0, 1.0]) {
      expect(
        downloadRetryDelay(
          retryIndex: 100,
          retryAfter: '  90  ',
          jitterUnit: jitter,
        ),
        const Duration(seconds: 90),
      );
      expect(
        downloadRetryDelay(
          retryIndex: 100,
          retryAfter: '0',
          jitterUnit: jitter,
        ),
        Duration.zero,
      );
    }
  });

  test('oversized Retry-After seconds saturate instead of overflowing', () {
    for (final value in ['9223372036855', '92233720368547758079999']) {
      expect(
        downloadRetryDelay(retryIndex: 0, retryAfter: value),
        const Duration(microseconds: 0x7FFFFFFFFFFFFFFF),
        reason: value,
      );
    }
  });

  test('malformed Retry-After falls back to local exponential backoff', () {
    for (final value in ['', '-1', '+7', '1.5', '0x10', 'later']) {
      expect(
        downloadRetryDelay(retryIndex: 2, retryAfter: value, jitterUnit: 0.5),
        const Duration(seconds: 1),
        reason: value,
      );
    }
  });

  test('configured recovery base grows exponentially', () {
    expect(
      planDownloadFailure(
        statusCode: 503,
        retryIndex: 2,
        baseDelay: const Duration(milliseconds: 10),
        jitterUnit: 0.5,
      ).delay,
      const Duration(milliseconds: 40),
    );
  });

  test('zero or negative recovery bases cannot create negative delays', () {
    for (final base in [Duration.zero, const Duration(seconds: -1)]) {
      expect(
        downloadRetryDelay(retryIndex: 2, baseDelay: base, jitterUnit: 1),
        Duration.zero,
      );
    }
  });

  test('very large recovery bases cannot overflow before the cap', () {
    expect(
      downloadRetryDelay(
        retryIndex: 1000000,
        baseDelay: const Duration(microseconds: 0x7FFFFFFFFFFFFFFF),
        jitterUnit: 0.5,
      ),
      kDownloadRetryMaxDelay,
    );
  });

  test('smallest recovery base still reaches the cap', () {
    expect(
      downloadRetryDelay(
        retryIndex: 1000000,
        baseDelay: const Duration(microseconds: 1),
        jitterUnit: 0.5,
      ),
      kDownloadRetryMaxDelay,
    );
  });

  test('Retry-After HTTP dates retain the full server delay', () {
    for (final header in [
      '  Fri, 16 Oct 2026 08:05:00 GMT  ',
      'Friday, 16-Oct-2026 08:05:00 GMT',
      'Fri Oct 16 08:05:00 2026',
    ]) {
      expect(
        planDownloadFailure(
          statusCode: 503,
          retryAfter: header,
          retryIndex: 20,
          baseDelay: const Duration(seconds: 1),
          jitterUnit: 1,
          now: DateTime.utc(2026, 10, 16, 8),
        ).delay,
        const Duration(minutes: 5),
        reason: header,
      );
    }
  });

  test('server Date preserves the wait when the local clock is fast', () {
    for (final responseDate in [
      'Fri, 16 Oct 2026 08:00:00 GMT',
      '  Friday, 16-Oct-26 08:00:00 GMT  ',
      'Fri Oct 16 08:00:00 2026',
    ]) {
      for (final minute in [1, 5]) {
        expect(
          planDownloadFailure(
            statusCode: 503,
            retryAfter: 'Fri, 16 Oct 2026 08:02:00 GMT',
            responseDate: responseDate,
            now: DateTime.utc(2026, 10, 16, 8, minute),
            jitterUnit: 0.5,
          ).delay,
          const Duration(minutes: 2),
          reason: '$responseDate at local minute $minute',
        );
      }
    }
  });

  test('server Date cannot shorten the wait when the local clock is slow', () {
    for (final responseDate in [
      'Fri, 16 Oct 2026 08:00:00 GMT',
      'Fri, 16 Oct 2026 08:04:00 GMT',
    ]) {
      expect(
        downloadRetryDelay(
          retryIndex: 0,
          retryAfter: 'Fri, 16 Oct 2026 08:02:00 GMT',
          responseDate: responseDate,
          now: DateTime.utc(2026, 10, 16, 7, 59),
          jitterUnit: 0.5,
        ),
        const Duration(minutes: 3),
      );
    }
  });

  test('missing or malformed server Date keeps the local-clock delay', () {
    for (final responseDate in [
      null,
      '',
      'later',
      'Fri, 99 Oct 2026 08:00:00 GMT',
      'Thu, 16 Oct 2026 08:00:00 GMT',
    ]) {
      expect(
        downloadRetryDelay(
          retryIndex: 0,
          retryAfter: 'Fri, 16 Oct 2026 08:02:00 GMT',
          responseDate: responseDate,
          now: DateTime.utc(2026, 10, 16, 8, 1),
          jitterUnit: 0.5,
        ),
        const Duration(minutes: 1),
        reason: responseDate,
      );
    }
  });

  test('a deadline past both clocks still allows an immediate retry', () {
    expect(
      downloadRetryDelay(
        retryIndex: 0,
        retryAfter: 'Fri, 16 Oct 2026 08:02:00 GMT',
        responseDate: 'Fri, 16 Oct 2026 08:04:00 GMT',
        now: DateTime.utc(2026, 10, 16, 8, 5),
        jitterUnit: 0.5,
      ),
      Duration.zero,
    );
  });

  test('server Date leaves numeric Retry-After seconds unchanged', () {
    expect(
      downloadRetryDelay(
        retryIndex: 0,
        retryAfter: '90',
        responseDate: 'Fri, 16 Oct 2026 08:00:00 GMT',
        now: DateTime.utc(2026, 10, 16, 8, 5),
        jitterUnit: 0.5,
      ),
      const Duration(seconds: 90),
    );
  });

  test('server Date cannot turn an invalid Retry-After into a server wait', () {
    expect(
      downloadRetryDelay(
        retryIndex: 0,
        retryAfter: 'later',
        responseDate: 'Fri, 16 Oct 2026 08:00:00 GMT',
        now: DateTime.utc(2026, 10, 16, 8, 5),
        jitterUnit: 0.5,
      ),
      kDownloadRetryBaseDelay,
    );
  });

  test('RFC-850 two-digit years use the current 100-year window', () {
    expect(
      downloadRetryDelay(
        retryIndex: 0,
        retryAfter: 'Friday, 16-Oct-26 08:05:00 GMT',
        now: DateTime.utc(2026, 10, 16, 8),
        jitterUnit: 0.5,
      ),
      const Duration(minutes: 5),
    );
    expect(
      downloadRetryDelay(
        retryIndex: 0,
        retryAfter: 'Friday, 01-Jan-00 00:00:00 GMT',
        now: DateTime.utc(2099, 12, 31),
        jitterUnit: 0.5,
      ),
      const Duration(days: 1),
    );
  });

  test('RFC-850 dates beyond 50 years use the previous century', () {
    expect(
      downloadRetryDelay(
        retryIndex: 0,
        retryAfter: 'Sunday, 16-Oct-77 08:05:00 GMT',
        now: DateTime.utc(2026, 10, 16, 8),
        jitterUnit: 0.5,
      ),
      Duration.zero,
    );
  });

  test('RFC-850 century resolution uses the exact 50-year boundary', () {
    final now = DateTime.utc(2026, 10, 16, 8, 5);
    expect(
      downloadRetryDelay(
        retryIndex: 0,
        retryAfter: 'Friday, 16-Oct-76 08:05:00 GMT',
        now: now,
        jitterUnit: 0.5,
      ),
      DateTime.utc(2076, 10, 16, 8, 5).difference(now),
    );
    expect(
      downloadRetryDelay(
        retryIndex: 0,
        retryAfter: 'Saturday, 16-Oct-76 08:05:00 GMT',
        now: now.subtract(const Duration(seconds: 1)),
        jitterUnit: 0.5,
      ),
      Duration.zero,
    );
  });

  test('RFC-850 leap dates are validated in the resolved century', () {
    expect(
      downloadRetryDelay(
        retryIndex: 0,
        retryAfter: 'Thursday, 29-Feb-24 00:00:00 GMT',
        now: DateTime.utc(2024, 2, 28),
        jitterUnit: 0.5,
      ),
      const Duration(days: 1),
    );
    expect(
      downloadRetryDelay(
        retryIndex: 0,
        retryAfter: 'Monday, 29-Feb-00 00:00:00 GMT',
        now: DateTime.utc(2051),
        jitterUnit: 0.5,
      ),
      kDownloadRetryBaseDelay,
    );
  });

  test(
    'invalid calendar and clock fields fall back instead of normalizing',
    () {
      for (final header in [
        'Fri, 99 Oct 2026 08:05:00 GMT',
        'Fri, 30 Feb 2026 08:05:00 GMT',
        'Fri, 29 Feb 2026 08:05:00 GMT',
        'Fri, 16 Oct 2026 24:05:00 GMT',
        'Fri, 16 Oct 2026 08:60:00 GMT',
        'Fri, 16 Oct 2026 08:05:60 GMT',
        'Thu, 16 Oct 2026 08:05:00 GMT',
        'Friday, 99-Oct-26 08:05:00 GMT',
        'Fri Oct 99 08:05:00 2026',
      ]) {
        expect(
          downloadRetryDelay(
            retryIndex: 2,
            retryAfter: header,
            now: DateTime.utc(2026, 10, 16, 8),
            jitterUnit: 0.5,
          ),
          const Duration(seconds: 1),
          reason: header,
        );
      }
    },
  );

  test('Retry-After HTTP dates use current time when it is not supplied', () {
    final before = DateTime.now();
    final delay = downloadRetryDelay(
      retryIndex: 0,
      retryAfter: 'Fri, 01 Jan 2100 00:00:00 GMT',
      jitterUnit: 0.5,
    );
    final after = DateTime.now();
    final deadline = DateTime.utc(2100);
    expect(delay, greaterThanOrEqualTo(deadline.difference(after)));
    expect(delay, lessThanOrEqualTo(deadline.difference(before)));
  });

  test('past and current Retry-After HTTP dates allow immediate retry', () {
    for (final now in [
      DateTime.utc(2026, 10, 16, 8, 5),
      DateTime.utc(2026, 10, 16, 8, 6),
    ]) {
      expect(
        downloadRetryDelay(
          retryIndex: 2,
          retryAfter: 'Fri, 16 Oct 2026 08:05:00 GMT',
          jitterUnit: 0.5,
          now: now,
        ),
        Duration.zero,
      );
    }
  });

  test('truncated HTTP dates fall back without a parse exception', () {
    for (final header in ['Fri ', 'Fri, ', 'Fri, 16 Oct']) {
      expect(
        downloadRetryDelay(
          retryIndex: 2,
          retryAfter: header,
          baseDelay: const Duration(milliseconds: 10),
          jitterUnit: 0.5,
          now: DateTime.utc(2026, 10, 16, 8),
        ),
        const Duration(milliseconds: 40),
        reason: header,
      );
    }
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

  test('connection failure enters network hold without backoff budget', () {
    final decision = planDownloadFailure(connectionFailure: true);
    expect(decision.action, DownloadFailureAction.waitForNetwork);
    expect(decision.delay, Duration.zero);
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
