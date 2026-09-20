import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
    test('V2 callers use logical control commands', () {
    final provider = File(
      'lib/features/library/presentation/downloads_provider.dart',
    ).readAsStringSync();
    final dialog = File(
      'lib/features/details/presentation/widgets/download_progress_dialog.dart',
    ).readAsStringSync();

    expect(provider, contains('downloadManagerV2Provider'));
    expect(provider, contains('.pause(DownloadLogicalId(logical))'));
    expect(provider, contains('.resume(DownloadLogicalId(logical))'));
    expect(dialog, contains('downloadManagerV2Provider'));
    expect(dialog, contains('.cancel(DownloadLogicalId(logical))'));
    expect(dialog, contains('resumeDownload(data.taskId)'));
    expect(dialog, contains('pauseDownload(data.taskId)'));
    expect(dialog, isNot(contains('downloadServiceProvider')));
  });

  test('V2 removal uses the logical manager and settles the visible row', () {
    final provider = File(
      'lib/features/library/presentation/downloads_provider.dart',
    ).readAsStringSync();

    final start = provider.indexOf('Future<void> removeDownloads(');
    final end = provider.indexOf(
      '\n  Future<void> pauseDownload(',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = provider.substring(start, end);

    expect(body, contains('downloadManagerV2Provider'));
    expect(body, contains('if (logical != null && logical.isNotEmpty)'));
    expect(body, contains('manager.delete(DownloadLogicalId(logical))'));
    expect(body, contains('_deletingIds.addAll(droppedIds)'));
    expect(body, contains('storage.removeDownloadMetadata('));
    expect(body, isNot(contains('FileDownloader().database.deleteRecordWithId')));
    expect(body, isNot(contains('.deleteDownloadOutcome(')));
    expect(body, isNot(contains('.cancelDownloadOutcome(')));
  });
}
