import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K platform CI contract', () {
    final workflowFile = File('.github/workflows/anime4k-platform-build.yml');

    test('dedicated Anime4K workflow stays removed after workflow cleanup', () {
      expect(workflowFile.existsSync(), isFalse);
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

    test('retired Anime4K branch plan stays removed after cleanup', () {
      expect(
        File('ANIME4K_PERFORMANCE_PLAN.md').existsSync(),
        isFalse,
        reason:
            'The completed branch plan was intentionally removed from main; CI must not resurrect or depend on it.',
      );
    });

    test('temporary one-shot preview workflow is removed before main merge', () {
      expect(
        File('.github/workflows/ios-preview-once.yml').existsSync(),
        isFalse,
      );
    });
  });
}
