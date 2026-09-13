import 'dart:convert';
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
      expect(source, contains('recordConfiguration'));
      expect(source, contains('recordRoute'));
      expect(source, contains('recordSnapshot'));
      expect(source, contains('segmentStart'));
      expect(source, contains('segmentEnd'));
      expect(source, contains('segmentId'));
      expect(source, contains('averageFrameTimeMs'));
      expect(source, contains('p95FrameTimeMs'));
      expect(source, contains('processedFrames'));
      expect(source, contains('skippedDuplicateFrames'));
      expect(source, contains('droppedOrLateFrames'));
      expect(source, contains('thermalLevel'));
      expect(source, contains('lowPowerMode'));
      expect(source, contains('metalFxExperiment'));
    });

    test('player configuration, samples, and routes use the same segmented log', () {
      final source = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();

      expect(
        source,
        contains("import '../data/anime4k_performance_log.dart';"),
      );
      expect(source, contains('anime4kPerformanceLogProvider'));
      expect(source, contains('.recordConfiguration('));
      expect(source, contains('.recordSnapshot('));
      expect(source, contains('.recordRoute('));
      expect(source, contains('anime4kMetalFxEnabled'));
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

      await log.recordConfiguration(
        enabled: true,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.s,
        ecoEnabled: true,
        metalFxExperiment: false,
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
      expect(text, contains('\"type\":\"session\"'));
      expect(text, contains('\"isPhysicalDevice\":true'));
      expect(text, contains('\"type\":\"segmentStart\"'));
      expect(text, contains('\"segmentId\":1'));
      expect(text, contains('\"type\":\"route\"'));
      expect(text, contains('\"backend\":\"metalEco\"'));
      expect(text, contains('\"type\":\"snapshot\"'));
      expect(text, contains('\"averageFrameTimeMs\":4.25'));
      expect(text, contains('\"p95FrameTimeMs\":5.75'));
      expect(text, contains('\"skippedDuplicateFrames\":120'));
    });

    test('setting changes create comparable segments in one session file', () async {
      final root = await Directory.systemTemp.createTemp(
        'anime4k-segment-log-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      var clock = DateTime.utc(2026, 9, 13, 7, 0);
      final log = Anime4kPerformanceLog(
        documentsDirectory: () async => root,
        deviceInfo: () async => <String, Object?>{
          'deviceModel': 'iPhone13,4',
          'isPhysicalDevice': true,
        },
        now: () => clock,
      );

      await log.recordConfiguration(
        enabled: true,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.s,
        ecoEnabled: false,
        metalFxExperiment: false,
      );
      // Repeating the same configuration must not split the benchmark.
      await log.recordConfiguration(
        enabled: true,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.s,
        ecoEnabled: false,
        metalFxExperiment: false,
      );
      await log.recordRoute(
        backend: Anime4kBackend.metal,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.s,
        ecoEnabled: false,
        metalFxExperiment: false,
        reason: 'metal-ready',
      );
      await log.recordSnapshot(
        const Anime4kPerformanceSnapshot(
          backend: Anime4kBackend.metal,
          requestedMode: Anime4kMode.a,
          requestedQuality: Anime4kQuality.s,
          effectiveQuality: Anime4kQuality.s,
          inputWidth: 1920,
          inputHeight: 1080,
          processingWidth: 1920,
          processingHeight: 1080,
          averageFrameTimeMs: 25.0,
          p95FrameTimeMs: 33.0,
          processedFrames: 240,
          skippedDuplicateFrames: 0,
          droppedOrLateFrames: 0,
          thermalLevel: Anime4kThermalLevel.fair,
          lowPowerMode: false,
        ),
        metalFxExperiment: false,
      );

      clock = clock.add(const Duration(seconds: 10));
      await log.recordConfiguration(
        enabled: true,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.s,
        ecoEnabled: false,
        metalFxExperiment: true,
      );
      await log.recordRoute(
        backend: Anime4kBackend.metal,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.s,
        ecoEnabled: false,
        metalFxExperiment: true,
        reason: 'metal-ready',
      );
      await log.recordSnapshot(
        const Anime4kPerformanceSnapshot(
          backend: Anime4kBackend.metal,
          requestedMode: Anime4kMode.a,
          requestedQuality: Anime4kQuality.s,
          effectiveQuality: Anime4kQuality.s,
          inputWidth: 1920,
          inputHeight: 1080,
          processingWidth: 1920,
          processingHeight: 1080,
          averageFrameTimeMs: 18.0,
          p95FrameTimeMs: 24.0,
          processedFrames: 250,
          skippedDuplicateFrames: 0,
          droppedOrLateFrames: 1,
          thermalLevel: Anime4kThermalLevel.fair,
          lowPowerMode: false,
        ),
        metalFxExperiment: true,
      );

      clock = clock.add(const Duration(seconds: 5));
      await log.recordConfiguration(
        enabled: false,
        mode: Anime4kMode.off,
        requestedQuality: Anime4kQuality.s,
        ecoEnabled: false,
        metalFxExperiment: false,
      );

      final directory = Directory('${root.path}${Platform.pathSeparator}log');
      final files = directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.log'))
          .toList();
      expect(files, hasLength(1));

      final events = await files.single
          .readAsLines()
          .then(
            (lines) => lines
                .map((line) => jsonDecode(line) as Map<String, dynamic>)
                .toList(),
          );
      final starts = events
          .where((event) => event['type'] == 'segmentStart')
          .toList();
      final ends = events
          .where((event) => event['type'] == 'segmentEnd')
          .toList();
      final routes = events.where((event) => event['type'] == 'route').toList();
      final snapshots = events
          .where((event) => event['type'] == 'snapshot')
          .toList();

      expect(starts, hasLength(3));
      expect(starts.map((event) => event['segmentId']), <Object?>[1, 2, 3]);
      expect(starts[0]['enabled'], isTrue);
      expect(starts[0]['metalFxExperiment'], isFalse);
      expect(starts[1]['enabled'], isTrue);
      expect(starts[1]['metalFxExperiment'], isTrue);
      expect(starts[2]['enabled'], isFalse);
      expect(starts[2]['mode'], Anime4kMode.off.name);

      expect(ends, hasLength(2));
      expect(ends[0]['segmentId'], 1);
      expect(ends[0]['durationMs'], 10000);
      expect(ends[0]['averageFrameTimeMs'], 25.0);
      expect(ends[0]['p95FrameTimeMs'], 33.0);
      expect(ends[0]['processedFrames'], 240);
      expect(ends[0]['droppedOrLateFrames'], 0);
      expect(ends[1]['segmentId'], 2);
      expect(ends[1]['durationMs'], 5000);
      expect(ends[1]['averageFrameTimeMs'], 18.0);
      expect(ends[1]['p95FrameTimeMs'], 24.0);
      expect(ends[1]['processedFrames'], 250);
      expect(ends[1]['droppedOrLateFrames'], 1);

      expect(routes.map((event) => event['segmentId']), <Object?>[1, 2]);
      expect(snapshots.map((event) => event['segmentId']), <Object?>[1, 2]);
    });

    test('physical-device diagnosis logs raw color state and samples manual Metal', () {
      final logSource = File(
        'lib/features/player/data/anime4k_performance_log.dart',
      ).readAsStringSync();
      final controller = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();

      expect(logSource, contains("'colorTransfer': colorTransfer"));
      expect(logSource, contains("'colorSystem': colorSystem"));
      expect(logSource, contains("'metalState': metalState"));
      expect(logSource, contains("'playerBackend': playerBackend"));

      final postApplyStart = controller.indexOf(
        'Future<void> _recordAnime4kPostApplyRoute',
      );
      final sampleStart = controller.indexOf('Future<void> _sampleAnime4kEco');
      expect(postApplyStart, greaterThanOrEqualTo(0));
      expect(sampleStart, greaterThan(postApplyStart));

      final setupBody = controller.substring(postApplyStart, sampleStart);
      expect(setupBody, contains("reason: 'metal-ready'"));
      expect(setupBody, contains('metalState:'));
      expect(setupBody, contains('playerBackend:'));

      final sampleEnd = controller.indexOf(
        'void _publishAnime4kPerformanceSnapshot',
        sampleStart,
      );
      expect(sampleEnd, greaterThan(sampleStart));
      final sampleBody = controller.substring(sampleStart, sampleEnd);
      final publish = sampleBody.indexOf(
        '_publishAnime4kPerformanceSnapshot(decision.snapshot);',
      );
      final ecoOnlyPolicyGuard = sampleBody.indexOf(
        'if (!settings.anime4kEcoEnabled) return;',
      );
      expect(publish, greaterThanOrEqualTo(0));
      expect(
        ecoOnlyPolicyGuard,
        greaterThan(publish),
        reason:
            'Manual Metal must publish telemetry before Eco-only policy exits.',
      );
    });
  });
}
