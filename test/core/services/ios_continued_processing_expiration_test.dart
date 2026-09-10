import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'continued-processing expiration ends only the OS lease, not the download',
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
        contains('task?.setTaskCompleted(success: false)'),
      );
      expect(expirationBlock, contains('self.activeTask = nil'));
      expect(expirationBlock, contains('self.identifier = nil'));
    },
  );
}
