import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/data/anime4k_eco_governor.dart';
import 'package:animewitcher/features/player/data/anime4k_metal_bridge.dart';
import 'package:animewitcher/features/player/data/anime4k_performance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K Eco governor', () {
    test('converts cumulative native late counters into per-sample pressure', () {
      final governor = Anime4kEcoGovernor(
        policy: Anime4kAdaptivePolicy(
          downgradeSamples: 1,
          recoverySamples: 4,
          cooldownSamples: 0,
        ),
      );

      final first = governor.sample(
        ecoEnabled: true,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.ul,
        telemetry: _telemetry(late: 5),
        frameBudgetMs: 16.67,
        source: const Anime4kProcessingDimensions(width: 1920, height: 1080),
        output: const Anime4kProcessingDimensions(width: 1178, height: 662),
      );
      expect(first.lateOrDroppedDelta, 5);
      expect(first.plan.effectiveQuality, Anime4kQuality.vl);

      final unchanged = governor.sample(
        ecoEnabled: true,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.ul,
        telemetry: _telemetry(late: 5),
        frameBudgetMs: 16.67,
        source: const Anime4kProcessingDimensions(width: 1920, height: 1080),
        output: const Anime4kProcessingDimensions(width: 1178, height: 662),
      );
      expect(unchanged.lateOrDroppedDelta, 0);
      expect(unchanged.plan.effectiveQuality, Anime4kQuality.vl);

      final resetCounter = governor.sample(
        ecoEnabled: true,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.ul,
        telemetry: _telemetry(late: 1),
        frameBudgetMs: 16.67,
        source: const Anime4kProcessingDimensions(width: 1920, height: 1080),
        output: const Anime4kProcessingDimensions(width: 1178, height: 662),
      );
      expect(resetCounter.lateOrDroppedDelta, 1);
    });

    test('uses p95 pressure but keeps requested quality as the saved ceiling', () {
      final governor = Anime4kEcoGovernor(
        policy: Anime4kAdaptivePolicy(
          downgradeSamples: 1,
          recoverySamples: 4,
          cooldownSamples: 0,
        ),
      );

      final decision = governor.sample(
        ecoEnabled: true,
        mode: Anime4kMode.bb,
        requestedQuality: Anime4kQuality.ul,
        telemetry: _telemetry(average: 4, p95: 15),
        frameBudgetMs: 16,
        source: const Anime4kProcessingDimensions(width: 1280, height: 720),
        output: const Anime4kProcessingDimensions(width: 1920, height: 1080),
      );

      expect(decision.plan.mode, Anime4kMode.bb);
      expect(decision.plan.effectiveQuality, Anime4kQuality.vl);
      expect(decision.snapshot.requestedQuality, Anime4kQuality.ul);
      expect(decision.snapshot.effectiveQuality, Anime4kQuality.vl);
      expect(decision.snapshot.backend, Anime4kBackend.metalEco);
      expect(decision.snapshot.averageFrameTimeMs, 4);
      expect(decision.snapshot.p95FrameTimeMs, 15);
      expect(decision.snapshot.processingWidth, 1920);
      expect(decision.snapshot.processingHeight, 1080);
    });

    test('critical thermal bypasses then recovers without changing mode', () {
      final governor = Anime4kEcoGovernor(
        policy: Anime4kAdaptivePolicy(
          downgradeSamples: 1,
          recoverySamples: 2,
          cooldownSamples: 0,
        ),
      );
      const source = Anime4kProcessingDimensions(width: 1280, height: 720);
      const output = Anime4kProcessingDimensions(width: 1280, height: 720);

      final critical = governor.sample(
        ecoEnabled: true,
        mode: Anime4kMode.ca,
        requestedQuality: Anime4kQuality.l,
        telemetry: _telemetry(thermal: Anime4kThermalLevel.critical),
        frameBudgetMs: 33.33,
        source: source,
        output: output,
      );
      expect(critical.plan.mode, Anime4kMode.ca);
      expect(critical.plan.bypass, isTrue);
      expect(critical.plan.effectiveQuality, Anime4kQuality.s);

      final recovering = governor.sample(
        ecoEnabled: true,
        mode: Anime4kMode.ca,
        requestedQuality: Anime4kQuality.l,
        telemetry: _telemetry(),
        frameBudgetMs: 33.33,
        source: source,
        output: output,
      );
      expect(recovering.plan.bypass, isTrue);

      final recovered = governor.sample(
        ecoEnabled: true,
        mode: Anime4kMode.ca,
        requestedQuality: Anime4kQuality.l,
        telemetry: _telemetry(),
        frameBudgetMs: 33.33,
        source: source,
        output: output,
      );
      expect(recovered.plan.bypass, isFalse);
      expect(recovered.plan.mode, Anime4kMode.ca);
      expect(recovered.plan.effectiveQuality, Anime4kQuality.s);
    });

    test('manual mode remains exact and reports Metal rather than Metal Eco', () {
      final governor = Anime4kEcoGovernor();
      final decision = governor.sample(
        ecoEnabled: false,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.ul,
        telemetry: _telemetry(
          p95: 100,
          late: 50,
          thermal: Anime4kThermalLevel.critical,
          lowPower: true,
        ),
        frameBudgetMs: 16.67,
        source: const Anime4kProcessingDimensions(width: 854, height: 480),
        output: const Anime4kProcessingDimensions(width: 1178, height: 662),
      );

      expect(decision.plan.effectiveQuality, Anime4kQuality.ul);
      expect(decision.plan.bypass, isFalse);
      expect(decision.snapshot.backend, Anime4kBackend.metal);
      expect(decision.snapshot.requestedQuality, Anime4kQuality.ul);
    });

    test('frame budget derives from fps and fails safe to 60 fps', () {
      expect(anime4kFrameBudgetMsFromFps(24), closeTo(41.6667, 0.001));
      expect(anime4kFrameBudgetMsFromFps(30), closeTo(33.3333, 0.001));
      expect(anime4kFrameBudgetMsFromFps(120), closeTo(8.3333, 0.001));
      expect(anime4kFrameBudgetMsFromFps(null), closeTo(16.6667, 0.001));
      expect(anime4kFrameBudgetMsFromFps(0), closeTo(16.6667, 0.001));
      expect(anime4kFrameBudgetMsFromFps(1000), closeTo(16.6667, 0.001));
    });
  });
}

Anime4kMetalTelemetry _telemetry({
  double average = 4,
  double p95 = 5,
  int processed = 120,
  int late = 0,
  int inputWidth = 1280,
  int inputHeight = 720,
  int processingWidth = 1280,
  int processingHeight = 720,
  Anime4kThermalLevel thermal = Anime4kThermalLevel.nominal,
  bool lowPower = false,
}) {
  return Anime4kMetalTelemetry(
    averageFrameTimeMs: average,
    p95FrameTimeMs: p95,
    processedFrames: processed,
    lateOrDroppedFrames: late,
    inputWidth: inputWidth,
    inputHeight: inputHeight,
    processingWidth: processingWidth,
    processingHeight: processingHeight,
    thermalLevel: thermal,
    lowPowerMode: lowPower,
  );
}
