import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active cancel intent persists before ownership cleanup', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final begin = source.indexOf('Future<void> cancelDownload(');
    final end = source.indexOf('Future<void> pauseDownload(', begin);
    final cancel = source.substring(begin, end);

    expect(
      cancel,
      contains('final existingJob = await _jobStore.get(taskId);'),
    );
    expect(
      cancel,
      contains('final cancelPersisted = await _checkpointLogicalJob('),
    );
    expect(cancel, contains('state: DownloadJobState.canceled'));
    expect(
      cancel,
      contains(
        r"throw StateError('Failed to persist cancel intent for $taskId')",
      ),
    );

    final checkpoint = cancel.indexOf(
      'final cancelPersisted = await _checkpointLogicalJob(',
    );
    expect(checkpoint, greaterThanOrEqualTo(0));
    expect(
      checkpoint,
      lessThan(cancel.indexOf('_terminalJobIds.add(taskId);')),
    );
    expect(
      checkpoint,
      lessThan(cancel.indexOf('await _rangeTransfers.stop(taskId);')),
    );
    expect(checkpoint, lessThan(cancel.indexOf('await _parallel.cancel(')));
    expect(
      checkpoint,
      lessThan(cancel.indexOf('await _nativeTransport.cancel(')),
    );
    expect(
      checkpoint,
      lessThan(cancel.indexOf('await FileDownloader().cancelTasksWithIds(')),
    );
    expect(
      checkpoint,
      lessThan(cancel.indexOf('await _jobStore.remove(taskId);')),
    );
  });
}
