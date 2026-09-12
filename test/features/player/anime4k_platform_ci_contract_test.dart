import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K platform CI contract', () {
    final workflowFile = File('.github/workflows/anime4k-platform-build.yml');

    test('runs the complete platform gate without the obsolete branch trigger', () {
      expect(workflowFile.existsSync(), isTrue);
      final workflow = workflowFile.readAsStringSync();

      expect(workflow, isNot(contains('feat/anime4k-mobile-gpu')));
      expect(workflow, contains('flutter analyze'));
      expect(workflow, contains('flutter test'));
      expect(workflow, contains('Verify full Anime4K v4.0.1 Metal corpus'));
      expect(workflow, contains('Test native Anime4K Metal runtime contract'));
      expect(workflow, contains('flutter build apk'));
      expect(workflow, contains('flutter build ios --release --no-codesign'));
      expect(workflow, contains('flutter build macos --release'));
    });

    test('keeps physical Apple benchmark evidence explicit and reproducible', () {
      final evidenceFile = File('docs/anime4k_performance_benchmark.md');
      expect(
        evidenceFile.existsSync(),
        isTrue,
        reason: 'AKP-18 requires a checked-in physical-device evidence template.',
      );

      final evidence = evidenceFile.readAsStringSync();
      for (final required in <String>[
        'Physical Apple device',
        'exact commit',
        'average Anime4K time',
        'p95 Anime4K time',
        'processed frames',
        'skipped duplicate frames',
        'late/dropped frames',
        'effective dimensions',
        'thermal',
        'Low Power Mode',
        'SDR',
        'HDR',
        'MetalFX',
        'PENDING',
      ]) {
        expect(
          evidence,
          contains(required),
          reason: 'Benchmark evidence must include: $required',
        );
      }

      expect(
        evidence,
        contains('Do not claim performance completion'),
        reason: 'The template must fail closed until real device evidence exists.',
      );
    });
  });
}
