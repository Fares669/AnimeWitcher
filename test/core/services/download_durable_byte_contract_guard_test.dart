import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('durable recovery never reconstructs bytes from percentages', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    expect(source, isNot(contains('(parallelProgress * totalSize).floor()')));
    expect(source, isNot(contains('(progress * expectedBytes).floor()')));
    expect(source, contains('_parallel.durableBytesFor(task.taskId)'));
  });

  test(
    'Range checkpoints are emitted only after an explicit flush boundary',
    () {
      final range = File('lib/core/services/download_range_transfer.dart')
          .readAsStringSync();
      expect(
        range,
        contains(
          'await output.flush();\n              await onState(written, total, false);',
        ),
      );
      final service = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      expect(
        RegExp(r'DownloadDurableByteProvenance\.rangeFlushed')
            .allMatches(service)
            .length,
        greaterThanOrEqualTo(3),
      );
    },
  );

  test('verified completion cannot persist expected size as byte evidence', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    expect(
      source,
      isNot(
        contains('durableBytes: expectedBytes > 0 ? expectedBytes : fileBytes'),
      ),
    );
    expect(source, contains('DownloadDurableByteProvenance.verifiedFinalFile'));
  });
}
