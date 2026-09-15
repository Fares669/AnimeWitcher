import 'dart:io';

import 'package:animewitcher/core/utils/download_resume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'durable logical size wins over smaller transient plugin projection',
    () {
      expect(
        authoritativeLifecycleExpectedBytes(
          jobExpectedBytes: 353053603,
          fingerprintExpectedBytes: 353053603,
          metadataExpectedBytes: 353053603,
          databaseExpectedBytes: 353053603,
          telemetryExpectedBytes: 110329255,
          projectedExpectedBytes: 110329255,
        ),
        353053603,
      );
    },
  );

  test('stable metadata wins when JobStore has not learned the size yet', () {
    expect(
      authoritativeLifecycleExpectedBytes(
        jobExpectedBytes: -1,
        fingerprintExpectedBytes: -1,
        metadataExpectedBytes: 500000000,
        databaseExpectedBytes: 110000000,
        telemetryExpectedBytes: 110000000,
        projectedExpectedBytes: 110000000,
      ),
      500000000,
    );
  });

  test('transient projections remain a last-resort fallback', () {
    expect(
      authoritativeLifecycleExpectedBytes(
        jobExpectedBytes: -1,
        fingerprintExpectedBytes: -1,
        metadataExpectedBytes: -1,
        databaseExpectedBytes: -1,
        telemetryExpectedBytes: 120000000,
        projectedExpectedBytes: 110000000,
      ),
      120000000,
    );
  });

  test('presentation total never shrinks on a transient chunk projection', () {
    expect(
      keepLastKnownExpectedBytes(
        incomingExpectedBytes: 110329255,
        lastKnownExpectedBytes: 353053603,
      ),
      353053603,
    );
    expect(
      keepLastKnownExpectedBytes(
        incomingExpectedBytes: 400000000,
        lastKnownExpectedBytes: 353053603,
      ),
      400000000,
    );
    expect(
      keepLastKnownExpectedBytes(
        incomingExpectedBytes: -1,
        lastKnownExpectedBytes: 353053603,
      ),
      353053603,
    );
  });

  test('pause wiring uses authoritative expected-size selector', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf(
      'Future<void> pauseDownload(String taskId) async',
    );
    final end = source.indexOf(
      'Future<void> resumeDownload(String taskId) async',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('authoritativeLifecycleExpectedBytes('));
    expect(body, contains('jobExpectedBytes: job?.expectedBytes'));
    expect(
      body,
      contains('fingerprintExpectedBytes: job?.fingerprint?.expectedBytes'),
    );
    expect(
      body,
      contains(
        'metadataExpectedBytes: downloadMetadataExpectedBytes(metadata)',
      ),
    );
    expect(body, contains('databaseExpectedBytes: record?.expectedFileSize'));
    expect(
      body,
      contains('telemetryExpectedBytes: _telemetry.expectedBytesFor(taskId)'),
    );
    expect(body, contains('projectedExpectedBytes: current?.totalSize'));
  });

  test('saved progress gives durable identity priority over transient totals', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('_savedProgressFor(DownloadTask task) async');
    final end = source.indexOf('Future<DownloadTask?> _liveNativeTaskFor(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('authoritativeLifecycleExpectedBytes('));
    expect(body, contains('jobExpectedBytes: job?.expectedBytes'));
    expect(
      body,
      contains('fingerprintExpectedBytes: job?.fingerprint?.expectedBytes'),
    );
    expect(
      body,
      contains('metadataExpectedBytes: downloadMetadataExpectedBytes(metadata)'),
    );
    expect(body, contains('databaseExpectedBytes: record?.expectedFileSize'));
    expect(
      body,
      contains(
        'telemetryExpectedBytes: _telemetry.expectedBytesFor(task.taskId)',
      ),
    );
    expect(body, contains('projectedExpectedBytes: current?.totalSize'));
  });

  test('system-pause preservation keeps JobStore size authoritative', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<void> _preserveDownloadAsPaused(');
    final end = source.indexOf(
      'Future<void> _startNextAfterParkedFailureUnlocked()',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('final job = await _jobStore.get(task.taskId);'));
    expect(body, contains('authoritativeLifecycleExpectedBytes('));
    expect(body, contains('jobExpectedBytes: job?.expectedBytes'));
    expect(
      body,
      contains('fingerprintExpectedBytes: job?.fingerprint?.expectedBytes'),
    );
  });

  test('UI projection refuses to regress a known logical total', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('void _publishProgress({');
    final end = source.indexOf('/// Process tapping on a notification', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('keepLastKnownExpectedBytes('));
    expect(body, contains('lastKnownExpectedBytes: previous?.totalSize'));
  });
}
