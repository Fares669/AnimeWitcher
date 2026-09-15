import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('live plugin parallel parent outranks stale failure callback', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<void> _retainLiveNativeOrPause(');
    final end = source.indexOf('Future<bool> _promoteWaitingTask(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('final live = await _liveNativeTaskFor('));
    expect(body, contains('if (live != null) {'));
    expect(body, contains('await _attachToLiveNativeTask('));
    expect(
      body,
      isNot(contains('live != null && update.task is! ParallelDownloadTask')),
      reason:
          'a live plugin ParallelDownloadTask is authoritative runtime evidence and must not be parked by a stale failed/canceled callback',
    );
  });

  test('live task lookup requires plugin runtime evidence', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<DownloadTask?> _liveNativeTaskFor({');
    final end = source.indexOf('Future<void> _attachToLiveNativeTask(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('_nativeTransport.handleFor(taskId)'));
    expect(body, contains('isLiveNativeDownloadStatus(transfer.status)'));
    expect(body, contains('for (final task in await _liveTransferTasks())'));
    expect(body, isNot(contains('database.recordForId')));
  });
}
