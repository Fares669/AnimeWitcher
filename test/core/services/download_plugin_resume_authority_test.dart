import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unchanged-source resume delegates lifecycle choice to Transfer.resume', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<bool> _resumeDownloadTask(');
    final end = source.indexOf('Future<bool> _resumeUsingPartialFile(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(
      body,
      isNot(contains('if (canNativeResume && !refreshResult.refreshed)')),
      reason:
          'DownloadService must not duplicate Transfer.resume resume-vs-reenqueue policy',
    );
    expect(body, contains('if (!refreshResult.refreshed) {'));
    final pluginResume = body.indexOf('await _nativeTransport.resume(task)');
    final fallback = body.indexOf('return resumeOrRestartDownload(');
    expect(pluginResume, greaterThanOrEqualTo(0));
    expect(fallback, greaterThan(pluginResume));
    expect(
      body.substring(pluginResume, fallback),
      contains('await _runtimeOwnershipFor(task.taskId)'),
      reason:
          'a rejected/missing Transfer must settle ownership before app recovery can start another writer',
    );
  });

  test('changed signed source keeps verified Range recovery outside plugin resume', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<bool> _resumeDownloadTask(');
    final end = source.indexOf('Future<bool> _resumeUsingPartialFile(', start);
    final body = source.substring(start, end);

    expect(body, contains('if (refreshResult.refreshed) {'));
    expect(body, contains('RefreshedTransferResumeMode.verifiedRangeFallback'));
    expect(body, contains('return _resumeUsingPartialFile(task);'));
    expect(
      body.indexOf('if (refreshResult.refreshed) {'),
      lessThan(body.indexOf('if (!refreshResult.refreshed) {')),
      reason:
          'resource replacement must be resolved before delegating unchanged-source lifecycle to Transfer.resume',
    );
  });
}
