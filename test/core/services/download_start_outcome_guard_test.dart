import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
