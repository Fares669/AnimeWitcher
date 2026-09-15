import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy multipart marks update provenance at its source', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final onUpdateStart = source.indexOf('onUpdate: (update) {');
    final onUpdateEnd = source.indexOf('availableStorageBytes:', onUpdateStart);
    expect(onUpdateStart, greaterThanOrEqualTo(0));
    expect(onUpdateEnd, greaterThan(onUpdateStart));
    final onUpdate = source.substring(onUpdateStart, onUpdateEnd);

    expect(source, contains('final Expando<bool> _legacyParallelUpdateOrigin'));
    expect(onUpdate, contains('_legacyParallelUpdateOrigin[update] = true;'));
    expect(
      onUpdate,
      contains('BackgroundDownloaderCompat.updateSyntheticNotification('),
      reason:
          'synthetic notification belongs only to the legacy executor callback',
    );
  });

  test('plugin parallel presentation is not selected by task shape', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final listenerStart = source.indexOf(
      '_updatesSubscription = _sharedEvents.stream.listen((update) {',
    );
    final listenerEnd = source.indexOf(
      '// 5. Bring the plugin executor',
      listenerStart,
    );
    expect(listenerStart, greaterThanOrEqualTo(0));
    expect(listenerEnd, greaterThan(listenerStart));
    final listener = source.substring(listenerStart, listenerEnd);

    expect(
      listener,
      contains(
        'final legacyParallelUpdate = _legacyParallelUpdateOrigin[update] == true;',
      ),
    );
    expect(
      listener,
      contains('final progress = legacyParallelUpdate'),
      reason:
          'only legacy parent telemetry may bypass monotonic plugin projection',
    );
    expect(
      listener,
      contains('final isAggregateMultipart = legacyParallelUpdate;'),
    );
    expect(
      listener,
      isNot(
        contains(
          'if (update is TaskStatusUpdate && update.task is ParallelDownloadTask)',
        ),
      ),
      reason:
          'plugin ParallelDownloadTask notifications are already owned by background_downloader',
    );
  });

  test('verified plugin completion does not synthesize a second notification', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<void> _handleVerifiedCompleteUpdate(');
    final end = source.indexOf('void _handleStatusUpdate(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(
      body,
      isNot(
        contains('BackgroundDownloaderCompat.updateSyntheticNotification('),
      ),
    );
  });
}
