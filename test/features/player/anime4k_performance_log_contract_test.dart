import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K in-app performance log contract', () {
    test('dedicated Anime4K logger persists device-local benchmark evidence', () {
      final file = File(
        'lib/features/player/data/anime4k_performance_log.dart',
      );
      expect(file.existsSync(), isTrue);
      final source = file.readAsStringSync();

      expect(source, contains('class Anime4kPerformanceLog'));
      expect(source, contains("'anime4k-'"));
      expect(source, contains('getApplicationDocumentsDirectory'));
      expect(source, contains("'log'"));
      expect(source, contains('DeviceInfoPlugin'));
      expect(source, contains('isPhysicalDevice'));
      expect(source, contains('recordRoute'));
      expect(source, contains('recordSnapshot'));
      expect(source, contains('averageFrameTimeMs'));
      expect(source, contains('p95FrameTimeMs'));
      expect(source, contains('processedFrames'));
      expect(source, contains('skippedDuplicateFrames'));
      expect(source, contains('droppedOrLateFrames'));
      expect(source, contains('thermalLevel'));
      expect(source, contains('lowPowerMode'));
      expect(source, contains('metalFxExperiment'));
    });

    test('player samples and route decisions are written to the same log', () {
      final source = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();

      expect(
        source,
        contains("import '../data/anime4k_performance_log.dart';"),
      );
      expect(source, contains('anime4kPerformanceLogProvider'));
      expect(source, contains('.recordSnapshot('));
      expect(source, contains('.recordRoute('));
    });

    test('Anime4K settings expose the local performance log inside the app', () {
      final source = File(
        'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
      ).readAsStringSync();

      expect(source, contains('Anime4K performance log'));
      expect(source, contains('سجل أداء Anime4K'));
      expect(source, contains('showAnime4kPerformanceLogDialog'));
    });
  });
}
