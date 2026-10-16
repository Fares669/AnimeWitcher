import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'unclassified continued-processing expiration does not cancel downloads',
    () async {
      // Normalised because this searches for literal newlines. Git checks the
      // file out with CRLF wherever core.autocrlf is on, which is the default
      // on Windows — there the '\n\n' below matches nothing and the test
      // fails on a tree that is perfectly correct.
      final source = (await File(
        'ios/Runner/DownloadContinuedProcessingManager.swift',
      ).readAsString()).replaceAll('\r\n', '\n');
      final start = source.indexOf('task.expirationHandler =');
      final end = source.indexOf('\n\n    if let snapshot', start);

      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));

      final expirationBlock = source.substring(start, end);
      expect(expirationBlock, isNot(contains('cancellationHandler?')));
      expect(
        expirationBlock,
        contains('completion.finish { task.setTaskCompleted(success: false) }'),
      );
      expect(expirationBlock, contains('self.activeTask = nil'));
      expect(expirationBlock, contains('self.identifier = nil'));
      expect(expirationBlock, isNot(contains('completeSession(')));
      expect(expirationBlock, isNot(contains('cancelPendingRequest(')));
    },
  );

  test('native continued processing has no unsupported system cancel bridge', () {
    final manager = File('ios/Runner/DownloadContinuedProcessingManager.swift')
        .readAsStringSync();
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    // Apple exposes the same reasonless expiration callback for OS expiry and
    // system UI cancellation. Do not wire it to an explicit app cancel action.
    expect(manager, isNot(contains('var cancellationHandler:')));
    expect(delegate, isNot(contains('.cancellationHandler =')));
  });
}
