import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DM-03 exposes typed pause resume and cancel outcomes', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    expect(
      source,
      contains('Future<DownloadCommandOutcome> pauseDownloadOutcome('),
    );
    expect(
      source,
      contains('Future<DownloadCommandOutcome> resumeDownloadOutcome('),
    );
    expect(
      source,
      contains('Future<DownloadCommandOutcome> cancelDownloadOutcome('),
    );
  });

  test('DM-03 callers use typed control settlement', () {
    final provider = File(
      'lib/features/library/presentation/downloads_provider.dart',
    ).readAsStringSync();
    final dialog = File(
      'lib/features/details/presentation/widgets/download_progress_dialog.dart',
    ).readAsStringSync();
    expect(provider, contains('.pauseDownloadOutcome(taskId)'));
    expect(provider, contains('.resumeDownloadOutcome(taskId)'));
    expect(dialog, contains('cancelDownloadOutcome('));
    expect(dialog, contains('resumeDownloadOutcome(data.taskId)'));
    expect(dialog, contains('pauseDownloadOutcome(data.taskId)'));
  });

  test('DM-07 removal delegates destructive cleanup to the service transaction', () {
    final provider = File(
      'lib/features/library/presentation/downloads_provider.dart',
    ).readAsStringSync();
    final service = File('lib/core/services/download_service.dart')
        .readAsStringSync();

    final start = provider.indexOf('Future<void> removeDownloads(');
    final end = provider.indexOf('\n  void _setOptimisticStatus(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = provider.substring(start, end);

    expect(body, contains('.deleteDownloadOutcome('));
    expect(body, contains('_deletingIds.addAll(droppedIds)'));
    expect(body, isNot(contains('FileDownloader().database.deleteRecordWithId')));
    expect(body, isNot(contains('removeDownloadMetadata(')));
    expect(body, isNot(contains('deleteDownloadedFile(')));
    expect(body, isNot(contains('.cancelDownload(')));
    expect(body, isNot(contains('.cancelDownloadOutcome(')));

    final deleteStart = service.indexOf(
      'Future<DownloadCommandOutcome> deleteDownloadOutcome(',
    );
    final deleteEnd = service.indexOf(
      'Future<DownloadCommandOutcome> pauseDownloadOutcome(',
      deleteStart,
    );
    expect(deleteStart, greaterThanOrEqualTo(0));
    expect(deleteEnd, greaterThan(deleteStart));
    final deleteBody = service.substring(deleteStart, deleteEnd);
    expect(deleteBody, contains('cancelDownloadOutcome('));
    expect(deleteBody, contains('DownloadRuntimeOwnership.notOwned'));
    expect(deleteBody, contains('deleteDownloadedFile(file)'));
    expect(deleteBody, contains('DownloadCommandOutcome.settlingOwnership'));
  });
}
