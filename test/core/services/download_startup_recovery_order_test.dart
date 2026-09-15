import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plugin startup and rehydrate precede legacy manifest inventory', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final initializeStart = source.indexOf('Future<void> _initialize() async {');
    final initializeEnd = source.indexOf(
      '  /// Test hook that replaces [FileDownloader.configure]',
      initializeStart,
    );
    expect(initializeStart, greaterThanOrEqualTo(0));
    expect(initializeEnd, greaterThan(initializeStart));
    final body = source.substring(initializeStart, initializeEnd);

    final restoreIntent = body.indexOf('await _restoreAuthoritativeJobIntent()');
    final listener = body.indexOf('_sharedEvents.stream.listen');
    final pluginStart = body.indexOf('await FileDownloader().start(');
    final rehydrate = body.indexOf(
      'await _nativeTransport.rehydrate(group: kLogicalDownloadGroup)',
    );
    final legacyInventory = body.indexOf(
      'for (final record in await FileDownloader().database.allRecords())',
    );
    final reconcile = body.indexOf(
      'await _serializeQueue(_recoverPersistedDownloads)',
    );

    for (final position in <int>[
      restoreIntent,
      listener,
      pluginStart,
      rehydrate,
      legacyInventory,
      reconcile,
    ]) {
      expect(position, greaterThanOrEqualTo(0));
    }

    expect(restoreIntent, lessThan(listener));
    expect(listener, lessThan(pluginStart));
    expect(pluginStart, lessThan(rehydrate));
    expect(rehydrate, lessThan(legacyInventory));
    expect(legacyInventory, lessThan(reconcile));
    expect(body, contains('doRescheduleKilledTasks: true'));
    expect(body, contains('markDownloadedComplete: false'));
  });
}
