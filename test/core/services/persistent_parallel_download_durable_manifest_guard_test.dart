import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('multipart manifest has exact per-part durable byte authority', () {
    final source = File('lib/core/services/persistent_parallel_download.dart')
        .readAsStringSync();

    expect(source, contains('kParallelManifestSchemaVersion = 5'));
    expect(source, contains("'durableBytes': durableBytes"));
    expect(source, contains('sum + part.durableBytes'));
    expect(
      source,
      contains('final savedDurableBytes = json[\'durableBytes\']'),
    );
  });
}
