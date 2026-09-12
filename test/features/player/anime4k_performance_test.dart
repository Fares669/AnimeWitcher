import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/data/anime4k_performance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K performance policy', () {
    test('manual mode never changes the requested quality', () {
      for (final quality in Anime4kQuality.values) {
        final plan = planAnime4kPerformance(
          ecoEnabled: false,
          mode: Anime4kMode.aa,
          requestedQuality: quality,
          thermalLevel: Anime4kThermalLevel.critical,
          lowPowerMode: true,
          rollingFrameTimeMs: 100,
          frameBudgetMs: 16.67,
        );

        expect(plan.mode, Anime4kMode.aa);
        expect(plan.effectiveQuality, quality);
        expect(plan.bypass, isFalse);
        expect(plan.reduceLateStages, isFalse);
      }
    });

    test('Eco never raises quality above the requested ceiling', () {
      final plan = planAnime4kPerformance(
        ecoEnabled: true,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.s,
        thermalLevel: Anime4kThermalLevel.nominal,
        lowPowerMode: false,
        rollingFrameTimeMs: 1,
        frameBudgetMs: 41.67,
      );

      expect(plan.mode, Anime4kMode.a);
      expect(plan.effectiveQuality, Anime4kQuality.s);
      expect(plan.bypass, isFalse);
    });

    test('fair thermal or sustained frame pressure steps down one tier', () {
      final fair = planAnime4kPerformance(
        ecoEnabled: true,
        mode: Anime4kMode.b,
        requestedQuality: Anime4kQuality.l,
        thermalLevel: Anime4kThermalLevel.fair,
        lowPowerMode: false,
        rollingFrameTimeMs: 8,
        frameBudgetMs: 33.33,
      );
      final pressured = planAnime4kPerformance(
        ecoEnabled: true,
        mode: Anime4kMode.b,
        requestedQuality: Anime4kQuality.l,
        thermalLevel: Anime4kThermalLevel.nominal,
        lowPowerMode: false,
        rollingFrameTimeMs: 27,
        frameBudgetMs: 33.33,
      );

      expect(fair.effectiveQuality, Anime4kQuality.m);
      expect(pressured.effectiveQuality, Anime4kQuality.m);
      expect(fair.mode, Anime4kMode.b);
      expect(pressured.mode, Anime4kMode.b);
    });

    test('serious thermal and Low Power Mode cap Eco at S', () {
      for (final input in <({Anime4kThermalLevel thermal, bool lowPower})>[
        (thermal: Anime4kThermalLevel.serious, lowPower: false),
        (thermal: Anime4kThermalLevel.nominal, lowPower: true),
      ]) {
        final plan = planAnime4kPerformance(
          ecoEnabled: true,
          mode: Anime4kMode.ca,
          requestedQuality: Anime4kQuality.ul,
          thermalLevel: input.thermal,
          lowPowerMode: input.lowPower,
          rollingFrameTimeMs: 5,
          frameBudgetMs: 33.33,
        );

        expect(plan.mode, Anime4kMode.ca);
        expect(plan.effectiveQuality, Anime4kQuality.s);
        expect(plan.bypass, isFalse);
        expect(plan.reduceLateStages, isTrue);
      }
    });

    test('critical thermal bypasses Anime4K only in Eco mode', () {
      final plan = planAnime4kPerformance(
        ecoEnabled: true,
        mode: Anime4kMode.a,
        requestedQuality: Anime4kQuality.m,
        thermalLevel: Anime4kThermalLevel.critical,
        lowPowerMode: false,
        rollingFrameTimeMs: 5,
        frameBudgetMs: 33.33,
      );

      expect(plan.mode, Anime4kMode.a);
      expect(plan.effectiveQuality, Anime4kQuality.s);
      expect(plan.bypass, isTrue);
      expect(plan.reduceLateStages, isTrue);
    });
  });

  test('performance snapshot carries diagnostics without platform dependencies', () {
    const snapshot = Anime4kPerformanceSnapshot(
      backend: Anime4kBackend.metalEco,
      requestedMode: Anime4kMode.a,
      requestedQuality: Anime4kQuality.m,
      effectiveQuality: Anime4kQuality.s,
      inputWidth: 1920,
      inputHeight: 1080,
      processingWidth: 1280,
      processingHeight: 720,
      averageFrameTimeMs: 9.5,
      p95FrameTimeMs: 13.2,
      processedFrames: 120,
      skippedDuplicateFrames: 360,
      droppedOrLateFrames: 1,
      thermalLevel: Anime4kThermalLevel.fair,
      lowPowerMode: false,
    );

    expect(snapshot.backend, Anime4kBackend.metalEco);
    expect(snapshot.requestedQuality, Anime4kQuality.m);
    expect(snapshot.effectiveQuality, Anime4kQuality.s);
    expect(snapshot.processedFrames, 120);
    expect(snapshot.skippedDuplicateFrames, 360);
    expect(snapshot.processingWidth, 1280);
  });
}
