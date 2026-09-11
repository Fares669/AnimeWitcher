import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('start exposes logical outcome while legacy bool delegates to it', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    expect(
      source,
      contains('Future<DownloadCommandOutcome> startDownloadOutcome('),
    );
    expect(source, contains('final outcome = await startDownloadOutcome('));
    expect(source, contains('DownloadCommandOutcome.attached'));
    expect(source, contains('DownloadCommandOutcome.queued'));
    expect(source, contains('DownloadCommandOutcome.alreadyComplete'));
    expect(source, contains('DownloadCommandOutcome.serviceUnavailable'));
    expect(source, contains('DownloadCommandOutcome.recoverableFailure'));
  });

  test('DM-03 launcher consumes typed logical start outcomes', () {
    final source = File(
      'lib/features/details/presentation/download_launcher.dart',
    ).readAsStringSync();
    expect(source, contains('await downloadService.startDownloadOutcome('));
    expect(source, isNot(contains('await downloadService.startDownload(')));
    expect(source, contains('DownloadCommandOutcome.running'));
    expect(source, contains('DownloadCommandOutcome.attached'));
    expect(source, contains('DownloadCommandOutcome.queued'));
    expect(source, contains('DownloadCommandOutcome.alreadyComplete'));
    expect(source, contains('DownloadCommandOutcome.serviceUnavailable'));
    expect(source, contains('DownloadCommandOutcome.restartRequired'));
    expect(source, contains('DownloadCommandOutcome.settlingOwnership'));
    expect(source, contains('await refreshStore.remove(resolveUrl)'));
  });

}
