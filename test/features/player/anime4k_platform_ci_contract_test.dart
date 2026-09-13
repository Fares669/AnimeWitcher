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
        reason: 'Final review requires a checked-in physical-device evidence template.',
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
        'PENDING',
      ]) {
        expect(
          evidence,
          contains(required),
          reason: 'Benchmark evidence must include: $required',
        );
      }

      expect(evidence, contains('Retired experiments'));
      expect(evidence, contains('Eco/Auto'));
      expect(evidence, contains('MetalFX'));
      expect(evidence, isNot(contains('segmentStart')));
      expect(evidence, isNot(contains('segmentEnd')));
      expect(
        evidence,
        contains('Do not claim performance completion'),
        reason: 'The template must fail closed until real device evidence exists.',
      );
    });

    test('source-of-truth plan matches the simplified shipping scope', () {
      final plan = File('ANIME4K_PERFORMANCE_PLAN.md').readAsStringSync();

      expect(plan, contains('Retired from shipping scope'));
      expect(plan, contains('Eco/Auto'));
      expect(plan, contains('MetalFX'));
      expect(plan, contains('Performance log'));
      expect(plan, isNot(contains('Expose a persisted experimental MetalFX toggle')));
      expect(plan, isNot(contains('Apple Eco/Auto is a separate Apple-only mode')));
    });

    test('temporary one-shot preview workflow is removed before main merge', () {
      expect(
        File('.github/workflows/ios-preview-once.yml').existsSync(),
        isFalse,
      );
    });
  });
}
