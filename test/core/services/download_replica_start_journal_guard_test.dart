import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DM-11 fresh start writes replica intent before any replica projection', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    final start = source.indexOf(
      'final transferTask = await _adaptiveTaskForFreshStart(',
    );
    final projection = source.indexOf(
      '_waitingPayloads[transferTask.taskId]',
      start,
    );

    expect(start, greaterThanOrEqualTo(0));
    expect(projection, greaterThan(start));

    final freshStartDurability = source.substring(start, projection);
    expect(
      freshStartDurability,
      contains('_jobStore.beginReplicaTransactionFromSeed('),
      reason:
          'fresh start must atomically create its first JobStore row together '
          'with the write-ahead replica intent',
    );
    expect(
      freshStartDurability,
      contains('DownloadReplicaOperation.start'),
    );
    expect(freshStartDurability, contains('intentData:'));
    expect(
      freshStartDurability,
      contains("'refreshDescriptor'"),
      reason:
          'the durable start intent must carry enough refresh data to repair '
          'a job-only replica after relaunch',
    );
    expect(
      freshStartDurability,
      isNot(contains('_jobStore.put(')),
      reason:
          'a standalone job-row write reopens the crash window before the '
          'replica intent is durable',
    );
  });
}
