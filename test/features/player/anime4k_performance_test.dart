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

  group('Anime4K adaptive Eco state machine', () {
    Anime4kAdaptivePolicy policy() => Anime4kAdaptivePolicy(
      downgradeSamples: 3,
      recoverySamples: 4,
      cooldownSamples: 2,
    );

    Anime4kEffectivePlan sample(
      Anime4kAdaptivePolicy policy, {
      bool ecoEnabled = true,
      Anime4kQuality requestedQuality = Anime4kQuality.ul,
      Anime4kThermalLevel thermal = Anime4kThermalLevel.nominal,
      bool lowPower = false,
      double frameTimeMs = 8,
      double frameBudgetMs = 16.67,
      int lateOrDroppedFrames = 0,
    }) {
      return policy.update(
        ecoEnabled: ecoEnabled,
        mode: Anime4kMode.a,
        requestedQuality: requestedQuality,
        thermalLevel: thermal,
        lowPowerMode: lowPower,
        rollingFrameTimeMs: frameTimeMs,
        frameBudgetMs: frameBudgetMs,
        lateOrDroppedFrames: lateOrDroppedFrames,
      );
    }

    test('manual mode resets adaptation and preserves the requested quality', () {
      final state = policy();
      for (var i = 0; i < 3; i++) {
        sample(state, frameTimeMs: 16);
      }
      expect(state.effectiveQuality, Anime4kQuality.l);

      final manual = sample(
        state,
        ecoEnabled: false,
        requestedQuality: Anime4kQuality.m,
        thermal: Anime4kThermalLevel.critical,
        lowPower: true,
        frameTimeMs: 100,
        lateOrDroppedFrames: 20,
      );

      expect(manual.effectiveQuality, Anime4kQuality.m);
      expect(manual.bypass, isFalse);
      expect(state.effectiveQuality, Anime4kQuality.m);
    });

    test('frame pressure must be sustained before one-tier downgrade', () {
      final state = policy();

      expect(sample(state, frameTimeMs: 16).effectiveQuality, Anime4kQuality.ul);
      expect(sample(state, frameTimeMs: 16).effectiveQuality, Anime4kQuality.ul);
      expect(sample(state, frameTimeMs: 16).effectiveQuality, Anime4kQuality.l);
    });

    test('one healthy sample breaks an unhealthy streak', () {
      final state = policy();

      sample(state, frameTimeMs: 16);
      sample(state, frameTimeMs: 16);
      sample(state, frameTimeMs: 5);
      expect(sample(state, frameTimeMs: 16).effectiveQuality, Anime4kQuality.ul);
      expect(sample(state, frameTimeMs: 16).effectiveQuality, Anime4kQuality.ul);
    });

    test('late or dropped frames participate in the same sustained pressure', () {
      final state = policy();

      sample(state, lateOrDroppedFrames: 1);
      sample(state, lateOrDroppedFrames: 2);
      final pressured = sample(state, lateOrDroppedFrames: 1);

      expect(pressured.effectiveQuality, Anime4kQuality.l);
    });

    test('cooldown prevents consecutive samples from cascading quality', () {
      final state = policy();
      for (var i = 0; i < 3; i++) {
        sample(state, frameTimeMs: 16);
      }
      expect(state.effectiveQuality, Anime4kQuality.l);

      sample(state, frameTimeMs: 16);
      sample(state, frameTimeMs: 16);
      expect(state.effectiveQuality, Anime4kQuality.l);
    });

    test('critical thermal bypasses immediately and recovery is progressive', () {
      final state = policy();
      final critical = sample(
        state,
        thermal: Anime4kThermalLevel.critical,
      );
      expect(critical.bypass, isTrue);
      expect(critical.effectiveQuality, Anime4kQuality.s);

      for (var i = 0; i < 3; i++) {
        final recovering = sample(state, frameTimeMs: 5);
        expect(recovering.bypass, isTrue);
      }
      final resumed = sample(state, frameTimeMs: 5);
      expect(resumed.bypass, isFalse);
      expect(resumed.effectiveQuality, Anime4kQuality.s);

      for (var i = 0; i < 4; i++) {
        sample(state, frameTimeMs: 5);
      }
      expect(state.effectiveQuality, Anime4kQuality.m);
    });

    test('serious thermal or Low Power Mode clamps to S without bypass', () {
      for (final input in <({Anime4kThermalLevel thermal, bool lowPower})>[
        (thermal: Anime4kThermalLevel.serious, lowPower: false),
        (thermal: Anime4kThermalLevel.nominal, lowPower: true),
      ]) {
        final state = policy();
        final plan = sample(
          state,
          thermal: input.thermal,
          lowPower: input.lowPower,
        );
        expect(plan.effectiveQuality, Anime4kQuality.s);
        expect(plan.bypass, isFalse);
        expect(plan.reduceLateStages, isTrue);
      }
    });

    test('healthy recovery never exceeds the viewer requested ceiling', () {
      final state = policy();
      sample(state, thermal: Anime4kThermalLevel.serious);

      for (var i = 0; i < 20; i++) {
        sample(
          state,
          requestedQuality: Anime4kQuality.m,
          frameTimeMs: 5,
        );
      }
      expect(state.effectiveQuality, Anime4kQuality.m);
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
