import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'manual Metal samples telemetry periodically without running Eco policy',
    () {
      final source = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();

      final setupStart = source.indexOf('_anime4kEcoHandle = handle;');
      final immediateSample = source.indexOf(
        'unawaited(_sampleAnime4kEco());',
        setupStart,
      );
      expect(setupStart, greaterThanOrEqualTo(0));
      expect(immediateSample, greaterThan(setupStart));

      final setupBody = source.substring(setupStart, immediateSample);
      expect(setupBody, contains('_anime4kEcoTimer ??= Timer.periodic'));
      expect(
        setupBody,
        isNot(contains('if (settings.anime4kEcoEnabled)')),
        reason:
            'Manual Metal/MetalFX benchmark segments need fresh telemetry too.',
      );

      final sampleStart = source.indexOf('Future<void> _sampleAnime4kEco');
      final publish = source.indexOf(
        '_publishAnime4kPerformanceSnapshot(decision.snapshot);',
        sampleStart,
      );
      final qualityPolicy = source.indexOf(
        'if (decision.plan.effectiveQuality != _anime4kEcoEffectiveQuality)',
        publish,
      );
      expect(sampleStart, greaterThanOrEqualTo(0));
      expect(publish, greaterThan(sampleStart));
      expect(qualityPolicy, greaterThan(publish));

      final afterPublish = source.substring(publish, qualityPolicy);
      expect(
        afterPublish,
        contains('if (!settings.anime4kEcoEnabled) return;'),
        reason:
            'Periodic manual telemetry must not apply Eco quality/bypass policy.',
      );
    },
  );
}
