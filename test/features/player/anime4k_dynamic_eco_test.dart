import 'dart:io';

import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/data/anime4k_performance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K dynamic Eco MetalFX policy', () {
    Anime4kEffectivePlan sample(
      Anime4kAdaptivePolicy policy, {
      bool ecoEnabled = true,
      Anime4kQuality requestedQuality = Anime4kQuality.s,
      double frameTimeMs = 5,
      Anime4kThermalLevel thermal = Anime4kThermalLevel.nominal,
      bool lowPowerMode = false,
    }) {
      return policy.update(
        ecoEnabled: ecoEnabled,
        mode: Anime4kMode.aa,
        requestedQuality: requestedQuality,
        thermalLevel: thermal,
        lowPowerMode: lowPowerMode,
        rollingFrameTimeMs: frameTimeMs,
        frameBudgetMs: 16.67,
        lateOrDroppedFrames: 0,
      );
    }

    test('manual mode never enables MetalFX or internal downscaling', () {
      final policy = Anime4kAdaptivePolicy(
        downgradeSamples: 1,
        recoverySamples: 1,
        cooldownSamples: 0,
      );

      final plan = sample(
        policy,
        ecoEnabled: false,
        frameTimeMs: 100,
        thermal: Anime4kThermalLevel.critical,
        lowPowerMode: true,
      );

      expect(plan.useMetalFx, isFalse);
      expect(plan.processingScale, 1.0);
      expect(plan.effectiveQuality, Anime4kQuality.s);
      expect(plan.bypass, isFalse);
    });

    test('sustained pressure activates MetalFX before reducing S any further', () {
      final policy = Anime4kAdaptivePolicy(
        downgradeSamples: 3,
        recoverySamples: 4,
        cooldownSamples: 0,
      );

      expect(sample(policy, frameTimeMs: 16).useMetalFx, isFalse);
      expect(sample(policy, frameTimeMs: 16).useMetalFx, isFalse);
      final pressured = sample(policy, frameTimeMs: 16);

      expect(pressured.effectiveQuality, Anime4kQuality.s);
      expect(pressured.useMetalFx, isTrue);
      expect(pressured.processingScale, closeTo(0.85, 0.001));
    });

    test('continued pressure lowers MetalFX processing scale to a 67 percent floor', () {
      final policy = Anime4kAdaptivePolicy(
        downgradeSamples: 1,
        recoverySamples: 1,
        cooldownSamples: 0,
      );

      final first = sample(policy, frameTimeMs: 16);
      final second = sample(policy, frameTimeMs: 16);
      final third = sample(policy, frameTimeMs: 16);
      final fourth = sample(policy, frameTimeMs: 16);

      expect(first.processingScale, closeTo(0.85, 0.001));
      expect(second.processingScale, closeTo(0.75, 0.001));
      expect(third.processingScale, closeTo(0.67, 0.001));
      expect(fourth.processingScale, closeTo(0.67, 0.001));
      expect(fourth.useMetalFx, isTrue);
    });

    test('healthy recovery progressively returns to full Anime4K', () {
      final policy = Anime4kAdaptivePolicy(
        downgradeSamples: 1,
        recoverySamples: 1,
        cooldownSamples: 0,
      );
      sample(policy, frameTimeMs: 16);
      sample(policy, frameTimeMs: 16);
      sample(policy, frameTimeMs: 16);

      expect(sample(policy, frameTimeMs: 5).processingScale, closeTo(0.75, 0.001));
      expect(sample(policy, frameTimeMs: 5).processingScale, closeTo(0.85, 0.001));
      final recovered = sample(policy, frameTimeMs: 5);
      expect(recovered.processingScale, 1.0);
      expect(recovered.useMetalFx, isFalse);
    });

    test('serious thermal or Low Power Mode immediately uses the lowest Eco scale', () {
      for (final input in <({Anime4kThermalLevel thermal, bool lowPower})>[
        (thermal: Anime4kThermalLevel.serious, lowPower: false),
        (thermal: Anime4kThermalLevel.nominal, lowPower: true),
      ]) {
        final policy = Anime4kAdaptivePolicy();
        final plan = sample(
          policy,
          requestedQuality: Anime4kQuality.ul,
          thermal: input.thermal,
          lowPowerMode: input.lowPower,
        );
        expect(plan.effectiveQuality, Anime4kQuality.s);
        expect(plan.useMetalFx, isTrue);
        expect(plan.processingScale, closeTo(0.67, 0.001));
      }
    });
  });

  test('Anime4K dialog exposes one Eco control and no separate MetalFX switch', () {
    final dialog = File(
      'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
    ).readAsStringSync();

    expect(dialog, isNot(contains('MetalFX (experimental)')));
    expect(dialog, isNot(contains('setAnime4kMetalFxEnabled')));
    expect(dialog, contains('Eco / Auto'));
    expect(dialog, contains('MetalFX'));
  });
}
