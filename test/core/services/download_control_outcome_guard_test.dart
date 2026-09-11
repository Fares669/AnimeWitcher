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
}
