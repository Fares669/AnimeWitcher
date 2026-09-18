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

  test('iOS V2 native child progress keeps system overlay live in background', () {
    final source = File(
      'ios/Runner/DownloadNativeWaitingQueue.swift',
    ).readAsStringSync();
    final start = source.indexOf(
      'private static func postV2ParallelChunkMetric',
    );
    final end = source.indexOf(
      'private static func handleSupportedPluginStatus',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final v2Bridge = source.substring(start, end);
    expect(v2Bridge, contains('if !isAppInForeground()'));
    expect(
      v2Bridge,
      contains('DownloadContinuedProcessingManager.shared.updateFromNativeIfCurrent('),
    );
    expect(
      v2Bridge,
      isNot(contains('promoteMultipart')),
      reason:
          'Background overlay refresh is presentation-only; V2 native code '
          'must not gain transport ownership.',
    );
  });


  test('native overlay refresh rejects stale V2 generations', () {
    final source = File(
      'ios/Runner/DownloadContinuedProcessingManager.swift',
    ).readAsStringSync();
    expect(source, contains('func updateFromNativeIfCurrent('));
    expect(
      source,
      contains('guard taskId == currentEpisodeTaskId'),
      reason: 'Late native child callbacks must not switch the system overlay.',
    );
  });


  test('iOS V2 parent progress bypasses legacy promotion gate for overlay only', () {
    final source = File(
      'ios/Runner/DownloadNativeWaitingQueue.swift',
    ).readAsStringSync();
    final start = source.indexOf(
      'private static func handleSupportedPluginProgress',
    );
    final end = source.indexOf(
      '#endif',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final handler = source.substring(start, end);
    final v2Overlay = handler.indexOf('id.hasPrefix("aw_v2_")');
    final legacyGate = handler.indexOf('guard nativePromotionAvailable else { return }');
    expect(v2Overlay, greaterThanOrEqualTo(0));
    expect(legacyGate, greaterThan(v2Overlay));
    expect(
      handler.substring(v2Overlay, legacyGate),
      contains('updateFromNativeIfCurrent('),
    );
  });
}
