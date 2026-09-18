import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('V2 exact resume never uses Transfer.resume auto re-enqueue fallback', () {
    final source = File(
      'lib/core/services/download_v2/background_downloader_gateway.dart',
    ).readAsStringSync();

    expect(
      source,
      isNot(contains('Future<bool> resume() => transfer.resume()')),
      reason:
          'Transfer.resume() intentionally re-enqueues from byte zero when '
          'resume data is unavailable.',
    );
    expect(
      source,
      contains('_downloader.resume(transfer.task)'),
      reason:
          'V2 exact resume must use the package lower-level resume path used '
          'by SkyStream and background_downloader parallel resume tests.',
    );
  });
}
