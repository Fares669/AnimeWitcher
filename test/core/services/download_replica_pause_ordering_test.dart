import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pause journals intent, executor ack, projection, then commit in order', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final begin = source.indexOf('Future<void> pauseDownload(String taskId)');
    final end = source.indexOf('Future<void> resumeDownload(String taskId)', begin);
    expect(begin, greaterThanOrEqualTo(0));
    expect(end, greaterThan(begin));
    final pause = source.substring(begin, end);

    final intent = pause.indexOf('_jobStore.beginReplicaTransaction(');
    final executor = pause.indexOf('didPause = await _pauseTransfer(');
    final ack = pause.indexOf(
      'DownloadReplicaTransactionPhase.executorAcknowledged',
    );
    final projecting = pause.indexOf(
      'DownloadReplicaTransactionPhase.projecting',
    );
    final pluginProjection = pause.indexOf(
      'await FileDownloader().database.updateRecord(',
    );
    final logicalProjection = pause.indexOf(
      'await _jobStore.updateForAttempt(',
    );
    final commit = pause.indexOf('_jobStore.commitReplicaTransaction(');

    expect(intent, greaterThanOrEqualTo(0));
    expect(intent, lessThan(executor));
    expect(ack, greaterThan(executor));
    expect(projecting, greaterThan(ack));
    expect(projecting, lessThan(pluginProjection));
    expect(pluginProjection, lessThan(logicalProjection));
    expect(commit, greaterThan(logicalProjection));
    expect(
      pause,
      contains('operation: DownloadReplicaOperation.pause'),
    );
  });
}
