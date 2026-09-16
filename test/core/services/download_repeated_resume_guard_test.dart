import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('repeated resume does not advance generation for an already-owned writer', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf(
      'Future<void> _resumeUserPausedUnlocked(String taskId)',
    );
    final end = source.indexOf('bool _isOccupyingTaskId(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    final preflightJob = body.indexOf(
      'final resumePreflightJob = await _jobStore.get(taskId);',
    );
    final preflightOwnership = body.indexOf(
      'final resumePreflightOwnership = await _runtimeOwnershipFor(taskId);',
    );
    final checkpoint = body.indexOf(
      'final checkpointed = await _checkpointLogicalJob(',
    );

    expect(
      preflightJob,
      greaterThanOrEqualTo(0),
      reason: 'resume must inspect durable intent before opening a new generation',
    );
    expect(preflightOwnership, greaterThan(preflightJob));
    expect(checkpoint, greaterThan(preflightOwnership));
    expect(
      body,
      contains('!downloadJobHasUserPauseIntent(resumePreflightJob.state)'),
    );
    expect(
      body,
      contains(
        'resumePreflightOwnership == DownloadRuntimeOwnership.owned',
      ),
    );
    expect(body, contains("diagnosticLog.record('resume.idempotentAttached'"));
    expect(
      body.substring(preflightOwnership, checkpoint),
      contains('return;'),
      reason:
          'a repeated resume must attach/no-op before checkpointing or advancing generation',
    );
  });
}
