import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'lifecycle checkpoints never turn percentage into durable byte truth',
    () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();

      expect(source, isNot(contains('(totalSize * progress).floor()')));
      expect(
        source,
        isNot(contains('(saved.totalSize * saved.progress).floor()')),
      );
      expect(
        source,
        isNot(contains('durableBytes: totalSize > 0 && progress > 0')),
      );
    },
  );
}
