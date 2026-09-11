import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String methodBody(String source, String signature, String nextSignature) {
  final start = source.indexOf(signature);
  final end = source.indexOf(nextSignature, start + signature.length);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $signature');
  expect(end, greaterThan(start), reason: 'missing boundary $nextSignature');
  return source.substring(start, end);
}

void main() {
  final source = File('lib/core/services/download_service.dart')
      .readAsStringSync();

  test('ordinary single-file pause requires runtime ownership settlement', () {
    final start = source.indexOf('Future<bool> _pauseTransfer(');
    expect(start, greaterThanOrEqualTo(0));
    final body = source.substring(start);

    expect(
      body,
      contains('var ownership = await _runtimeOwnershipFor(task.taskId);'),
    );
    expect(body, contains('ownership != DownloadRuntimeOwnership.notOwned'));
    expect(
      body,
      isNot(
        contains(
          'if (isInternalDownloaderChunk(task)) {\n        // Verify the child really left the live native set',
        ),
      ),
      reason: 'ownership proof must not be restricted to multipart children',
    );
  });

  test('unsettled user pause stays durable pausing instead of rolling back to running', () {
    final body = methodBody(
      source,
      'Future<void> pauseDownload(String taskId) async {',
      'Future<void> resumeDownload(String taskId) async {',
    );
    final failedPause = body.substring(
      body.indexOf('if (!didPause) {'),
      body.indexOf(
        'await FileDownloader().database.updateRecord(',
        body.indexOf('if (!didPause) {'),
      ),
    );

    expect(failedPause, contains("diagnosticLog.record('pause.settling'"));
    expect(failedPause, isNot(contains('_userPausedIds.remove(taskId)')));
    expect(failedPause, isNot(contains('DownloadJobState.running')));
    expect(failedPause, isNot(contains('TaskStatus.running')));
  });

  test('startup pause projection is conditional on proven settlement', () {
    final recovery = methodBody(
      source,
      'Future<void> _recoverPersistedDownloads() async {',
      'int _occupiedSlotCount(',
    );

    expect(recovery, contains('var userPauseSettled = !userPaused;'));
    expect(
      recovery,
      contains('userPauseSettled = await _pauseTransfer(task);'),
    );
    expect(
      recovery,
      contains(
        'if (userPauseSettled) {\n          await FileDownloader().database.updateRecord(',
      ),
    );
    expect(recovery, contains('(userPaused && userPauseSettled)'));
  });
}
