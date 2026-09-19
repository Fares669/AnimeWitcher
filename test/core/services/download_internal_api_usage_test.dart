import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
    test('internal plugin access stays isolated in one compatibility seam', () {
    const compatPath = 'lib/core/services/download_plugin_compat.dart';
    final productionDartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in productionDartFiles) {
      if (file.path.replaceAll('\\', '/') == compatPath) continue;
      expect(
        file.readAsStringSync(),
        isNot(contains('.downloaderForTesting')),
        reason: '${file.path} bypasses BackgroundDownloaderCompat',
      );
    }

    final compat = File(compatPath).readAsStringSync();
    // 9.6 still lacks public APIs for raw ResumeData, synthetic custom-parent
    // notification updates, and clearing all notification configurations.
    expect(
      RegExp(r'FileDownloader\(\)\.downloaderForTesting')
          .allMatches(compat)
          .length,
      3,
    );
  });
}
