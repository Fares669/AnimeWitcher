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
      // Anchored on the closure assignment itself: the file also contains
      // an earlier 'task.expirationHandler = nil' detach assignment, which
      // must not match. The block ends at the closure's own closing brace —
      // the first following line indented exactly like the assignment. An
      // earlier version delimited the block by a later statement in
      // attach(); inserting unrelated lines there (the presentation-clock
      // reset, 29b0fb1d) broke that marker on a tree that is correct.
      final start = source.indexOf('task.expirationHandler = {');
      final end = source.indexOf('\n    }', start);

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
