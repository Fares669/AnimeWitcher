import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source replacement is gated by an authoritative checkpoint', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    const declaration =
        'Future<({DownloadTask task, bool refreshed, bool restartRequired})>';
    final begin = source.indexOf(declaration);
    final signature = source.indexOf('_refreshTaskBeforeResume(', begin);
    final end = source.indexOf(
      'Future<List<Task>> _liveTransferTasks()',
      signature,
    );
    expect(begin, greaterThanOrEqualTo(0));
    expect(signature, greaterThan(begin));
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
    final parallelReplacement = refresh.indexOf(
      'await _parallel.replaceSource(',
    );
    final nativeProjection = refresh.indexOf(
      'await FileDownloader().database.updateRecord(',
    );
    expect(checkpoint, greaterThanOrEqualTo(0));
    expect(parallelReplacement, greaterThan(checkpoint));
    expect(nativeProjection, greaterThan(checkpoint));
  });
}
