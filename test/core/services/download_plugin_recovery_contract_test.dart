import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _methodBody(String source, String signature, String nextSignature) {
  final start = source.indexOf(signature);
  final end = source.indexOf(nextSignature, start + signature.length);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $signature');
  expect(end, greaterThan(start), reason: 'missing boundary $nextSignature');
  return source.substring(start, end);
}

void main() {
  test('plugin startup settles before legacy inventory and reconciliation', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final initialize = _methodBody(
      source,
      'Future<void> _initialize() async {',
      'Future<void> _startPluginExecutor() async {',
    );

    final restoreIntent = initialize.indexOf(
      'await _restoreAuthoritativeJobIntent()',
    );
    final listener = initialize.indexOf('_sharedEvents.stream.listen');
    final pluginStart = initialize.indexOf('await _startPluginExecutor()');
    final legacyInventory = initialize.indexOf(
      'for (final record in await FileDownloader().database.allRecords())',
    );
    final reconcile = initialize.indexOf(
      'await _serializeQueue(_recoverPersistedDownloads)',
    );

    for (final position in <int>[
      restoreIntent,
      listener,
      pluginStart,
      legacyInventory,
      reconcile,
    ]) {
      expect(position, greaterThanOrEqualTo(0));
    }
    expect(restoreIntent, lessThan(listener));
    expect(listener, lessThan(pluginStart));
    expect(pluginStart, lessThan(legacyInventory));
    expect(legacyInventory, lessThan(reconcile));
  });

  test('plugin executor waits for native inventory before killed-task reschedule', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final helper = _methodBody(
      source,
      'Future<void> _startPluginExecutor() async {',
      '  /// Test hook that replaces [FileDownloader.configure]',
    );

    final start = helper.indexOf('await FileDownloader().start(');
    final cancelRogue = helper.indexOf('cancelTasksWithIds(');
    final settle = helper.indexOf(
      'await Future<void>.delayed(const Duration(seconds: 5));',
    );
    final reschedule = helper.indexOf(
      'await FileDownloader().rescheduleKilledTasks()',
    );
    final rehydrate = helper.indexOf(
      'await _nativeTransport.rehydrate(group: kLogicalDownloadGroup)',
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(settle, greaterThan(start));
    expect(cancelRogue, greaterThan(settle));
    expect(reschedule, greaterThan(cancelRogue));
    expect(rehydrate, greaterThan(reschedule));
    expect(helper, contains('doRescheduleKilledTasks: false'));
    expect(helper, contains('markDownloadedComplete: false'));
  });
}
