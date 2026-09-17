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

  test('DM-03 launcher starts through the V2 logical manager', () {
    final source = File(
      'lib/features/details/presentation/download_launcher.dart',
    ).readAsStringSync();

    expect(source, contains('downloadManagerV2Provider'));
    expect(source, contains('await downloadManager.start('));
    expect(source, contains('DownloadStartRequestV2('));
    expect(source, contains('sourceDescriptor: descriptor.toJson()'));
    expect(source, isNot(contains('downloadServiceProvider')));
    expect(source, isNot(contains('startDownloadOutcome(')));
  });

  test('DM-31 launcher passes refresh descriptor through V2 request', () {
    final source = File(
      'lib/features/details/presentation/download_launcher.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('final descriptor = DownloadUrlRefreshDescriptor('),
    );
    expect(source, contains('sourceDescriptor: descriptor.toJson()'));
    expect(source, contains('downloadManagerV2Provider'));
    expect(source, isNot(contains('await refreshStore.save(')));
    expect(source, isNot(contains('await refreshStore.remove(resolveUrl)')));
  });
}
