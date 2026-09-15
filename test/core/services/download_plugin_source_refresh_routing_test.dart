import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parallel source refresh uses legacy replacement only with manifest evidence', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf(
      'Future<({DownloadTask task, bool refreshed, bool restartRequired})>\n  _refreshTaskBeforeResume(',
    );
    final end = source.indexOf('Future<List<Task>> _liveTransferTasks()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('final legacySessionExists ='));
    expect(body, contains('await _parallel.restore(task)'));
    expect(body, contains('if (legacySessionExists) {'));
    expect(body, contains('await _parallel.replaceSource('));
    expect(
      body,
      isNot(
        contains(
          'if (task is ParallelDownloadTask) {\n      final replaced = await _parallel.replaceSource(',
        ),
      ),
      reason: 'ParallelDownloadTask shape is not proof of legacy ownership',
    );
  });

  test('plugin parallel opaque resume data never migrates into legacy refresh', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf(
      'Future<({DownloadTask task, bool refreshed, bool restartRequired})>\n  _refreshTaskBeforeResume(',
    );
    final end = source.indexOf('Future<List<Task>> _liveTransferTasks()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('hasOpaqueNativeResume'));
    expect(body, contains('!legacySessionExists'));
    expect(body, contains('restartRequired: true'));
  });

  test('resume asks background_downloader about resumability for parallel parents too', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<bool> _resumeDownloadTask(');
    final end = source.indexOf('Future<bool> _resumeUsingPartialFile(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('final canNativeResume = await _canNativeResume(task);'));
    expect(
      body,
      isNot(contains('task is! ParallelDownloadTask && await _canNativeResume(task)')),
    );
  });

  test('plugin refreshed task remains in background_downloader database and Transfer path', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf(
      'Future<({DownloadTask task, bool refreshed, bool restartRequired})>\n  _refreshTaskBeforeResume(',
    );
    final end = source.indexOf('Future<List<Task>> _liveTransferTasks()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('final updated = task.copyWith('));
    expect(body, contains('FileDownloader().database.updateRecord('));
    expect(body, contains('_nativeTransport.forget(task.taskId)'));
  });
}
