import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('lib/core/services/persistent_parallel_download.dart')
      .readAsStringSync();

  test('exact-size multipart adoption still requires writer settlement', () {
    final start = source.indexOf('Future<bool> _adoptExactSizePart(');
    final end = source.indexOf('void _capSessionAt(', start);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing adoption seam');
    expect(end, greaterThan(start), reason: 'missing adoption boundary');
    final body = source.substring(start, end);

    final settleStart = body.indexOf('if (settleNativeOwner) {');
    final verifyAgain = body.indexOf(
      'if (!await file.exists() || await file.length() != part.size) return false;',
      settleStart,
    );
    expect(settleStart, greaterThanOrEqualTo(0));
    expect(verifyAgain, greaterThan(settleStart));
    final settlement = body.substring(settleStart, verifyAgain);

    expect(settlement, contains('await pausePart(part.task);'));
    expect(
      settlement,
      contains('return false;'),
      reason:
          'bytesVerified must not imply ownerSettled when the native pause/ownership acknowledgement fails',
    );
  });

  test('tail recovery cannot relaunch after failed owner settlement', () {
    final start = source.indexOf('Future<void> _recoverTailStall(');
    final end = source.indexOf('Future<void> _recycleStalledTailRange(', start);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing tail recovery seam');
    expect(end, greaterThan(start), reason: 'missing recycle boundary');
    final body = source.substring(start, end);

    final pauseCall = body.indexOf('await pausePart(part.task);');
    final scheduleRecovery = body.indexOf('_schedulePartRecovery(session, part);');
    expect(pauseCall, greaterThanOrEqualTo(0));
    expect(scheduleRecovery, greaterThan(pauseCall));
    final settlement = body.substring(pauseCall, scheduleRecovery);

    expect(
      settlement,
      contains('part.tailRecoveryAttempted = false;'),
      reason: 'an unsettled owner must stay retryable instead of advancing recycle state',
    );
    expect(
      settlement,
      contains('return;'),
      reason: 'failed pause/ownership settlement must fence relaunch',
    );
  });

  test('tail recycle preserves ownership evidence until cancel settles', () {
    final start = source.indexOf('Future<void> _recycleStalledTailRange(');
    final end = source.indexOf('Future<bool> _adoptExactSizePart(', start);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing recycle seam');
    expect(end, greaterThan(start), reason: 'missing adoption boundary');
    final body = source.substring(start, end);

    final cancelCall = body.indexOf('await cancelParts(<String>[part.task.taskId]);');
    final releaseEvidence = body.indexOf('_activeConnectionIds.remove(part.task.taskId);');
    expect(cancelCall, greaterThanOrEqualTo(0));
    expect(
      releaseEvidence,
      greaterThan(cancelCall),
      reason: 'active/launched ownership evidence must survive until cancel settles',
    );

    final catchStart = body.indexOf('catch (_)', cancelCall);
    final releaseAfterCatch = body.indexOf('_activeConnectionIds.remove', catchStart);
    expect(catchStart, greaterThan(cancelCall));
    expect(releaseAfterCatch, greaterThan(catchStart));
    final failedSettlement = body.substring(catchStart, releaseAfterCatch);
    expect(
      failedSettlement,
      contains('return;'),
      reason: 'failed/unknown cancel settlement must not recycle or relaunch',
    );
  });
}
