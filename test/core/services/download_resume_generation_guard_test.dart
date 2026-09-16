import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('user resume reuses one durable execution generation', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();

    final commandStart = source.indexOf(
      'Future<void> _resumeUserPausedUnlocked(String taskId)',
    );
    final commandEnd = source.indexOf('bool _isOccupyingTaskId(', commandStart);
    expect(commandStart, greaterThanOrEqualTo(0));
    expect(commandEnd, greaterThan(commandStart));
    final command = source.substring(commandStart, commandEnd);

    expect(command, contains('final resumeOperation = await _jobStore.beginOperation('));
    expect(
      command,
      contains(
        'await _resumeDownloadTask(\n'
        '          downloadTask,\n'
        '          executionToken: resumeOperation,\n'
        '        )',
      ),
      reason:
          'the command generation must be handed into the executor path instead of opening a second generation',
    );

    final helperStart = source.indexOf('Future<bool> _resumeDownloadTask(');
    final helperEnd = source.indexOf(
      'Future<bool> _resumeUsingPartialFile(',
      helperStart,
    );
    expect(helperStart, greaterThanOrEqualTo(0));
    expect(helperEnd, greaterThan(helperStart));
    final helper = source.substring(helperStart, helperEnd);

    expect(
      helper,
      contains('DownloadAttemptToken? executionToken'),
      reason: 'resume execution must accept an already-open command generation',
    );
    expect(
      helper,
      contains('if (currentJob != null && executionToken == null) {'),
      reason:
          'internal recovery may open a generation only when the caller did not already provide one',
    );
    expect(
      helper,
      contains('executionToken = await _jobStore.beginOperation('),
    );
  });
}
