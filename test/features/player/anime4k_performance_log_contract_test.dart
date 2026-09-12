import 'dart:io';

import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/data/anime4k_performance.dart';
import 'package:animewitcher/features/player/data/anime4k_performance_log.dart';
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

    test('route and snapshot events share a JSONL session log', () async {
      final root = await Directory.systemTemp.createTemp('anime4k-log-test-');
      addTearDown(() => root.delete(recursive: true));
      final now = DateTime.utc(2026, 9, 12, 18, 0);
      final log = Anime4kPerformanceLog(
        documentsDirectory: () async => root,
        deviceInfo: () async => <String, Object?>{
          'deviceModel': 'iPhone17,1',
          'isPhysicalDevice': true,
        },
        now: () => now,
      );

      await log.recordRoute(
        backend: Anime4kBackend.metalEco,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.s,
        ecoEnabled: true,
        metalFxExperiment: false,
        colorSignal: 'sdr',
        reason: 'post-apply',
      );
      await log.recordSnapshot(
        const Anime4kPerformanceSnapshot(
          backend: Anime4kBackend.metalEco,
          requestedMode: Anime4kMode.a,
          requestedQuality: Anime4kQuality.s,
          effectiveQuality: Anime4kQuality.s,
          inputWidth: 1920,
          inputHeight: 1080,
          processingWidth: 1178,
          processingHeight: 662,
          averageFrameTimeMs: 4.25,
          p95FrameTimeMs: 5.75,
          processedFrames: 120,
          skippedDuplicateFrames: 120,
          droppedOrLateFrames: 1,
          thermalLevel: Anime4kThermalLevel.nominal,
          lowPowerMode: false,
        ),
        metalFxExperiment: false,
      );

      final text = await log.readLatest();
      expect(text, isNotNull);
      expect(text, contains('"type":"session"'));
      expect(text, contains('"isPhysicalDevice":true'));
      expect(text, contains('"type":"route"'));
      expect(text, contains('"backend":"metalEco"'));
      expect(text, contains('"type":"snapshot"'));
      expect(text, contains('"averageFrameTimeMs":4.25'));
      expect(text, contains('"p95FrameTimeMs":5.75'));
      expect(text, contains('"skippedDuplicateFrames":120'));
    });
  });
}
