import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plugin resume delegates fallback semantics to Transfer.resume', () {
    final source = File(
      'lib/core/services/background_downloader_transport.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'Future<bool> resume(DownloadTask task) async',
    );
    final end = source.indexOf(
      'Future<DownloadTransportCommandOutcome> startOutcome(',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('_downloader.transfers.getOrStart('));
    expect(body, contains('await transfer.resume()'));
    expect(body, contains('reEnqueueIfFailed: false'));
    expect(body, isNot(contains('await _downloader.resume(task)')));
    expect(body, isNot(contains('_downloader.taskCanResume(')));
  });

  test(
    'plugin fresh start delegates duplicate lookup to Transfers.getOrStart',
    () {
      final source = File(
        'lib/core/services/background_downloader_transport.dart',
      ).readAsStringSync();
      final start = source.indexOf(
        'Future<bool> start(DownloadTask task) async',
      );
      final end = source.indexOf(
        'Future<bool> pause(DownloadTask task) async',
        start,
      );
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(body, contains('_downloader.transfers.getOrStart('));
      expect(body, contains('reEnqueueIfFailed: false'));
      expect(body, isNot(contains('_downloader.transfers.start(task)')));
    },
  );
}
