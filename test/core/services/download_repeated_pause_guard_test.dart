import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('repeated settled pause does not open another generation', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<void> pauseDownload(String taskId)');
    final end = source.indexOf('Future<void> resumeDownload(String taskId)', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    final preflightJob = body.indexOf(
      'final pausePreflightJob = await _jobStore.get(taskId);',
    );
    final preflightOwnership = body.indexOf(
      'final pausePreflightOwnership = await _runtimeOwnershipFor(taskId);',
    );
    final checkpoint = body.indexOf(
      'final checkpointed = await _checkpointLogicalJob(',
    );

    expect(
      preflightJob,
      greaterThanOrEqualTo(0),
      reason: 'pause must inspect durable state before journaling another pause',
    );
    expect(preflightOwnership, greaterThan(preflightJob));
    expect(checkpoint, greaterThan(preflightOwnership));
    expect(
      body,
      contains('pausePreflightJob?.state == DownloadJobState.pausedByUser'),
    );
    expect(
      body,
      contains(
        'pausePreflightOwnership == DownloadRuntimeOwnership.notOwned',
      ),
    );
    expect(body, contains("diagnosticLog.record('pause.idempotentSettled'"));
    expect(
      body.substring(preflightOwnership, checkpoint),
      contains('return;'),
      reason:
          'a repeated settled pause must return before checkpointing or opening a replica transaction',
    );
  });
}
