import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS bridges V2 parallel child progress as read-only metrics', () {
    final source = File(
      'ios/Runner/DownloadNativeWaitingQueue.swift',
    ).readAsStringSync();

    expect(source, contains('postV2ParallelChunkMetric'));
    expect(source, contains('parentId.hasPrefix("aw_v2_")'));
    expect(
      source,
      contains('AnimeWitcherBackgroundDownloaderChunkUpdate'),
    );
    expect(
      source,
      isNot(contains('promoteV2Parallel')),
      reason: 'V2 native callbacks are metrics only, never transport ownership.',
    );
  });
}
