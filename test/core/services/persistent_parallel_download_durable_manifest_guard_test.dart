import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('multipart manifest has exact bytes and parent recovery authority', () {
    final source = File('lib/core/services/persistent_parallel_download.dart')
        .readAsStringSync();

    expect(source, contains('kParallelManifestSchemaVersion = 6'));
    expect(source, contains("'parentTask': session.task.toJson()"));
    expect(source, contains("'durableBytes': durableBytes"));
    expect(source, contains('sum + part.durableBytes'));
    expect(
      source,
      contains('final savedDurableBytes = json[\'durableBytes\']'),
    );
  });
}
