import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active delete intent tombstones before ownership cleanup', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final begin = source.indexOf('Future<void> cancelDownload(');
    final end = source.indexOf(
      'Future<DownloadCommandOutcome> cancelDownloadOutcome(',
      begin,
    );
    final cancel = source.substring(begin, end);

    expect(
      cancel,
      contains('final existingJob = await _jobStore.get(taskId);'),
    );
    expect(cancel, contains('_jobStore.tombstoneForDeletion(deletionSeed)'));
    expect(cancel, contains('state: DownloadJobState.canceled'));
    expect(
      cancel,
      contains(
        r"throw StateError('Failed to persist delete tombstone for $taskId')",
      ),
    );

    final tombstone = cancel.indexOf('_jobStore.tombstoneForDeletion(');
    expect(tombstone, greaterThanOrEqualTo(0));
    expect(tombstone, lessThan(cancel.indexOf('_terminalJobIds.add(taskId);')));
    expect(tombstone, lessThan(cancel.indexOf('await _rangeTransfers.stop(taskId);')));
    expect(tombstone, lessThan(cancel.indexOf('await _parallel.cancel(')));
    expect(tombstone, lessThan(cancel.indexOf('await _nativeTransport.cancel(')));
    expect(
      tombstone,
      lessThan(cancel.indexOf('await FileDownloader().cancelTasksWithIds(')),
    );
    expect(cancel, isNot(contains('await _jobStore.remove(taskId);')));
  });
}
