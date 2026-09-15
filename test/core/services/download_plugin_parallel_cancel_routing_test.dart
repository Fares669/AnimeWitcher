import 'dart:io';

import 'package:animewitcher/core/services/download_transport_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parallel control target', () {
    test('ordinary logical task is plugin-owned without a legacy query', () {
      expect(
        selectDownloadExecutorControlTarget(
          isParallelTask: false,
          legacyQuerySucceeded: false,
          legacySessionExists: false,
        ),
        DownloadExecutorControlTarget.plugin,
      );
    });

    test('parallel task with a proven legacy session stays legacy-owned', () {
      expect(
        selectDownloadExecutorControlTarget(
          isParallelTask: true,
          legacyQuerySucceeded: true,
          legacySessionExists: true,
        ),
        DownloadExecutorControlTarget.legacy,
      );
    });

    test('parallel task without a legacy manifest is plugin-owned', () {
      expect(
        selectDownloadExecutorControlTarget(
          isParallelTask: true,
          legacyQuerySucceeded: true,
          legacySessionExists: false,
        ),
        DownloadExecutorControlTarget.plugin,
      );
    });

    test(
      'parallel task fails closed when legacy ownership cannot be queried',
      () {
        expect(
          selectDownloadExecutorControlTarget(
            isParallelTask: true,
            legacyQuerySucceeded: false,
            legacySessionExists: false,
          ),
          DownloadExecutorControlTarget.unknown,
        );
      },
    );
  });

  test('system cancel pauses whichever executor actually owns the task', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<void> _cancelFromSystemUI(');
    final end = source.indexOf('Future<void> cancelDownload(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('await _pauseTransfer(downloadTask)'));
    expect(body, isNot(contains('downloadTask is ParallelDownloadTask')));
    expect(body, isNot(contains('_parallel.pause(downloadTask')));
  });

  test(
    'destructive cancel routes through ownership evidence, not task shape',
    () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      final start = source.indexOf('Future<void> cancelDownload(');
      final end = source.indexOf(
        'Future<DownloadCommandOutcome> cancelDownloadOutcome(',
        start,
      );
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(
        body,
        contains('final controlTarget = await _controlTargetFor(cancelTask);'),
      );
      expect(body, contains('DownloadExecutorControlTarget.legacy'));
      expect(body, contains('DownloadExecutorControlTarget.plugin'));
      expect(body, contains('DownloadExecutorControlTarget.unknown'));
      expect(body, contains('await _nativeTransport.cancel(cancelTask)'));
      expect(body, contains('await _parallel.cancel(cancelTask)'));
      expect(
        body,
        isNot(contains('if (parentRecord?.task is ParallelDownloadTask)')),
        reason:
            'ParallelDownloadTask is a task shape, not legacy ownership proof',
      );
    },
  );

  test('control target queries legacy manifest evidence behind one helper', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf(
      'Future<DownloadExecutorControlTarget> _controlTargetFor(',
    );
    final end = source.indexOf('Future<bool> _pauseTransfer(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('task is! ParallelDownloadTask'));
    expect(body, contains('await _parallel.restore(task)'));
    expect(body, contains('legacyQuerySucceeded: true'));
    expect(body, contains('legacyQuerySucceeded: false'));
  });
}
