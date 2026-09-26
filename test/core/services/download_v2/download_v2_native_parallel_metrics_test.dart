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
    expect(
      v2Bridge,
      contains(
        'task.group == "chunk" || task.group == "animewitcher_parts"',
      ),
      reason:
          'V2 durable iOS range children use animewitcher_parts, while the '
          'older package ParallelDownloadTask children use chunk. Both are '
          'read-only child telemetry for the same V2 parent overlay.',
    );
    expect(v2Bridge, contains('if !isAppInForeground()'));
    expect(
      v2Bridge,
      contains('DownloadContinuedProcessingManager.shared.updateFromNativeIfCurrent('),
    );
    expect(
      v2Bridge,
      contains('progress: nil'),
      reason:
          'Observed child ranges are only a subset of the parent until every '
          'range has reported. Their subtotal must never become parent progress.',
    );
    expect(
      v2Bridge,
      isNot(contains('aggregateProgress')),
      reason:
          'Dividing aggregate bytes by only observed child ranges caused the '
          '31/62/93% background jumps seen on the physical iOS log.',
    );
    expect(
      v2Bridge,
      isNot(contains('totalBytesHint: aggregateExpected')),
      reason: 'Observed child ranges are not the full parent byte length.',
    );
    expect(
      v2Bridge,
      isNot(contains('totalBytesHint: staleAggregateExpected')),
      reason: 'A stale child sample cannot become the parent total either.',
    );
    expect(
      RegExp(r'totalBytesHint: -1').allMatches(v2Bridge).length,
      greaterThanOrEqualTo(2),
      reason:
          'Both live and stale child telemetry must defer to an already-known '
          'full parent size instead of inventing one.',
    );
    expect(v2Bridge, contains('progress: nil'));
    expect(
      v2Bridge,
      isNot(
        contains('Double(aggregateWritten) / Double(aggregateExpected)'),
      ),
      reason:
          'Observed children are not necessarily the full parent denominator.',
    );
    expect(
      v2Bridge,
      isNot(contains('promoteMultipart')),
      reason:
          'Background overlay refresh is presentation-only; V2 native code '
          'must not gain transport ownership.',
    );
  });


  test('iOS V2 child progress is throttled before the Flutter bridge', () {
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
    expect(v2Bridge, contains('var shouldBridgeToDart = false'));
    expect(v2Bridge, contains('now - lastBridge >= chunkBridgeInterval'));
    expect(v2Bridge, contains('else if !appIsBackground'));
    expect(v2Bridge, contains('if shouldBridgeToDart'));
    expect(
      v2Bridge,
      contains('if completed || statusOrdinal != nil'),
      reason: 'pause/completion transitions must never be sampled away',
    );
  });


  test('V2 persists generation-fenced native refill plans before suspension', () {
    final gateway = File(
      'lib/core/services/download_v2/background_downloader_gateway.dart',
    ).readAsStringSync();
    final observer = File(
      'lib/core/services/download_v2/download_continued_processing_v2.dart',
    ).readAsStringSync();
    final provider = File(
      'lib/core/services/download_v2/download_v2_provider.dart',
    ).readAsStringSync();

    expect(gateway, contains('nativeBackgroundPlansV2'));
    expect(gateway, contains('nativeBackgroundPlans()'));
    expect(observer, contains('nativeBackgroundPlans'));
    expect(observer, contains('persistNativeQueue('));
    expect(observer, contains('multipartPlans: plans'));
    expect(
      provider,
      contains('nativeBackgroundPlans: packageGateway.nativeBackgroundPlansV2'),
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
    expect(source, contains('hasAuthoritativeByteCoverage'));
    expect(source, contains('totalBytesHint >= current.totalBytes'));
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
