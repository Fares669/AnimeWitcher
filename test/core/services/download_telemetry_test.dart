import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/services/download_telemetry.dart';

void main() {
  group('DownloadTelemetryEstimator', () {
    test('derives stable speed from a multi-second byte window', () {
      final estimator = DownloadTelemetryEstimator();
      final start = DateTime(2026, 1, 1, 12);

      estimator.observe(
        taskId: 'one',
        transferredBytes: 0,
        expectedBytes: 20 * 1000 * 1000,
        now: start,
      );
      estimator.observe(
        taskId: 'one',
        transferredBytes: 1 * 1000 * 1000,
        expectedBytes: 20 * 1000 * 1000,
        now: start.add(const Duration(seconds: 1)),
      );
      final reading = estimator.observe(
        taskId: 'one',
        transferredBytes: 3 * 1000 * 1000,
        expectedBytes: 20 * 1000 * 1000,
        now: start.add(const Duration(seconds: 3)),
      );

      expect(reading.speedBytesPerSecond, closeTo(1000 * 1000, 1));
      expect(reading.timeRemaining.inSeconds, 17);
      expect(reading.expectedBytes, 20 * 1000 * 1000);
    });

    test(
      'ignores a late byte regression instead of creating nonsense speed',
      () {
        final estimator = DownloadTelemetryEstimator();
        final start = DateTime(2026, 1, 1, 12);

        estimator.observe(
          taskId: 'one',
          transferredBytes: 10 * 1000 * 1000,
          expectedBytes: 100 * 1000 * 1000,
          now: start,
        );
        estimator.observe(
          taskId: 'one',
          transferredBytes: 12 * 1000 * 1000,
          expectedBytes: 100 * 1000 * 1000,
          now: start.add(const Duration(seconds: 2)),
        );
        final reading = estimator.observe(
          taskId: 'one',
          transferredBytes: 2 * 1000 * 1000,
          expectedBytes: 100 * 1000 * 1000,
          now: start.add(const Duration(seconds: 3)),
        );

        expect(reading.transferredBytes, 12 * 1000 * 1000);
        expect(reading.speedBytesPerSecond, closeTo(1000 * 1000, 1));
      },
    );

    test('uses median reported speed when byte totals are unavailable', () {
      final estimator = DownloadTelemetryEstimator();
      final start = DateTime(2026, 1, 1, 12);

      estimator.observe(
        taskId: 'unknown',
        fallbackSpeedBytesPerSecond: 500000,
        now: start,
      );
      estimator.observe(
        taskId: 'unknown',
        fallbackSpeedBytesPerSecond: 12000000,
        now: start.add(const Duration(milliseconds: 200)),
      );
      final reading = estimator.observe(
        taskId: 'unknown',
        fallbackSpeedBytesPerSecond: 600000,
        now: start.add(const Duration(milliseconds: 400)),
      );

      // The 12MB/s callback burst is an outlier; median stays near reality.
      expect(reading.speedBytesPerSecond, 600000);
    });

    test('fresh native speed survives sparse byte callbacks', () {
      final estimator = DownloadTelemetryEstimator();
      final start = DateTime(2026, 1, 1, 12);

      estimator.observe(
        taskId: 'sparse',
        transferredBytes: 1_000_000,
        expectedBytes: 10_000_000,
        fallbackSpeedBytesPerSecond: 100_000,
        now: start,
      );
      final reading = estimator.observe(
        taskId: 'sparse',
        transferredBytes: 1_000_000,
        expectedBytes: 10_000_000,
        fallbackSpeedBytesPerSecond: 120_000,
        now: start.add(const Duration(seconds: 4)),
      );

      expect(
        reading.speedBytesPerSecond,
        greaterThan(0),
        reason:
            'fresh native throughput must not be zeroed only because byte '
            'progress callbacks are sparse across one immutable Range',
      );
    });

    test('speed becomes zero after no bytes for stale timeout', () {
      final estimator = DownloadTelemetryEstimator();
      final start = DateTime(2026, 1, 1, 12);

      estimator.observe(
        taskId: 'stall',
        transferredBytes: 0,
        expectedBytes: 10000000,
        now: start,
      );
      final moving = estimator.observe(
        taskId: 'stall',
        transferredBytes: 1000000,
        expectedBytes: 10000000,
        now: start.add(const Duration(seconds: 1)),
      );
      expect(moving.speedBytesPerSecond, greaterThan(0));

      final stale = estimator.current(
        'stall',
        now: start.add(const Duration(seconds: 5)),
      );
      expect(stale.speedBytesPerSecond, 0);
      expect(stale.timeRemaining, Duration.zero);
    });

    test('native expected size survives speed reset', () {
      final estimator = DownloadTelemetryEstimator();
      estimator.seed('resume', expectedBytes: 188000000);
      estimator.resetSpeed('resume');
      expect(estimator.expectedBytesFor('resume'), 188000000);
    });
  });
}
