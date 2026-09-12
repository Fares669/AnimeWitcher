import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source replacement is gated by an authoritative checkpoint', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final signature = source.indexOf('_refreshTaskBeforeResume(');
    final begin = source.lastIndexOf('Future<', signature);
    final end = source.indexOf(
      'Future<List<Task>> _liveTransferTasks()',
      signature,
    );
    expect(signature, greaterThanOrEqualTo(0));
    expect(begin, greaterThanOrEqualTo(0));
    expect(end, greaterThan(signature));
    final refresh = source.substring(begin, end);

    expect(
      refresh,
      contains('final refreshCheckpointed = await _checkpointLogicalJob('),
    );
    expect(refresh, contains('state: DownloadJobState.interrupted'));
    expect(
      refresh,
      contains(r'Failed to persist source refresh boundary for ${task.taskId}'),
    );

    final checkpoint = refresh.indexOf(
      'final refreshCheckpointed = await _checkpointLogicalJob(',
    );
    expect(checkpoint, greaterThanOrEqualTo(0));
    expect(
      checkpoint,
      lessThan(refresh.indexOf('await _parallel.replaceSource(')),
    );
    expect(
      checkpoint,
      lessThan(
        refresh.indexOf('await FileDownloader().database.updateRecord('),
      ),
    );
  });
}
