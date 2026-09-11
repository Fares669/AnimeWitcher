import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native cancel keeps tracking until independent ownership proof', () {
    final source = File('lib/core/services/download_transport.dart')
        .readAsStringSync();
    final classStart = source.indexOf(
      'class NativeSingleDownloadTransport implements DownloadTransport',
    );
    final start = source.indexOf(
      'Future<DownloadCancelSettlement> cancel(',
      classStart,
    );
    final end = source.indexOf('\n  void forget(', start);
    expect(classStart, greaterThanOrEqualTo(0));
    expect(start, greaterThan(classStart));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);
    expect(body, isNot(contains('_detach(task.taskId)')));
    expect(body, contains('resolveDownloadCancelCommand('));
    expect(body, contains('hadTrackedOwner: transfer != null'));
    expect(body, contains('commandSucceeded: canceled'));
    expect(body, contains('commandThrew: true'));
  });

  test(
    'service gates destructive cancel cleanup on runtime notOwned proof',
    () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      expect(
        source,
        contains(
          'Future<DownloadRuntimeOwnership> _waitForCancelOwnershipRelease(',
        ),
      );
      expect(source, contains("'cancel.ownershipUnsettled'"));
      expect(
        source,
        contains('if (cancelOwnership != DownloadRuntimeOwnership.notOwned)'),
      );
      expect(source, contains('await _jobStore.remove(taskId);'));

      final callbackStart = source.indexOf('cancelParts: (ids) async {');
      final callbackEnd = source.indexOf('saveRecord:', callbackStart);
      expect(callbackStart, greaterThanOrEqualTo(0));
      expect(callbackEnd, greaterThan(callbackStart));
      final callback = source.substring(callbackStart, callbackEnd);
      expect(callback, contains('await _waitForCancelOwnershipRelease(id)'));
      expect(callback, contains('Multipart cancel ownership did not settle'));
    },
  );
}
