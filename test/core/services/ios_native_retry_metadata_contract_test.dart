import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native failure headers are cached before any asynchronous status bridge',
    () {
      final source = File('ios/Runner/DownloadNativeWaitingQueue.swift')
          .readAsStringSync();
      final begin = source.indexOf(
        '  private static func handleSupportedPluginStatus(',
      );
      final end = source.indexOf(
        '  private static func handleSupportedPluginProgress(',
        begin,
      );
      final callback = source.substring(begin, end);
      expect(callback, contains('DownloadNativeRetryMetadata.record('));
      expect(
        callback.indexOf('DownloadNativeRetryMetadata.record('),
        lessThan(callback.indexOf('postV2ParallelChunkMetric(')),
      );
      expect(callback, contains('statusUpdate.responseHeaders'));
      expect(callback, contains('statusUpdate.exception?.httpResponseCode'));
      expect(callback, isNot(contains('DispatchQueue')));
    },
  );

  test('retry metadata lookup is available before iOS 26 overlay checks', () {
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final channel = delegate.indexOf(
      'name: "com.animewitcher.app/download_continued_processing"',
    );
    final bridge = delegate.indexOf(
      'if call.method == "retryMetadataForRange"',
      channel,
    );
    expect(bridge, greaterThan(channel));
    expect(
      bridge,
      lessThan(delegate.indexOf('guard #available(iOS 26.0, *)', channel)),
    );
    expect(delegate, contains('DownloadNativeRetryMetadata.lookup(arguments)'));
  });
  test(
    'native admission and Dart export cannot bypass unresolved retry metadata',
    () {
      final native = File('ios/Runner/DownloadNativeWaitingQueue.swift')
          .readAsStringSync();
      final begin = native.indexOf(
        '  private static func isImmutableRangeWaiter(',
      );
      final end = native.indexOf(
        '  private static func parentMayRefillLocked(',
        begin,
      );
      expect(
        native.substring(begin, end),
        contains('DownloadNativeRetryMetadata.lookup('),
      );
      final dart = File('lib/core/services/persistent_parallel_download.dart')
          .readAsStringSync();
      final plans = dart.substring(
        dart.indexOf(
          '  List<NativeParallelBackgroundPlan> nativeBackgroundPlans()',
        ),
        dart.indexOf(
          '  ///',
          dart.indexOf(
                '  List<NativeParallelBackgroundPlan> nativeBackgroundPlans()',
              ) +
              5,
        ),
      );
      expect(plans, contains('part.pendingRetryMetadataGeneration != null'));
    },
  );
  test('uncommitted retry checkpoints wait for bounded recovery rather than repump', () {
    final source = File('lib/core/services/persistent_parallel_download.dart')
        .readAsStringSync();
    final begin = source.indexOf('  Iterable<_DownloadPart> _launchableParts(');
    final end = source.indexOf('  int _launchablePartCount(', begin);
    expect(
      source.substring(begin, end),
      contains('!part.retryCheckpointPending'),
    );
    final recovery = source.substring(
      source.indexOf('  void _scheduleCoordinatorRecovery('),
      source.indexOf('  void _schedulePumpAll('),
    );
    expect(recovery, contains('part.retryCheckpointPending'));
  });
}
