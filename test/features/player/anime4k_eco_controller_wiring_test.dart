import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K Eco controller wiring', () {
    late String source;

    setUpAll(() {
      source = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();
    });

    test('samples live Metal status and telemetry at a low fixed cadence', () {
      expect(source, contains("import '../data/anime4k_eco_governor.dart';"));
      expect(
        source,
        contains('Timer.periodic(const Duration(seconds: 1)'),
      );

      final sample = source.indexOf('Future<void> _sampleAnime4kEco()');
      final status = source.indexOf('metalBridge.status(handle: handle)', sample);
      final telemetry = source.indexOf(
        'metalBridge.telemetry(handle: handle)',
        status,
      );
      expect(sample, greaterThanOrEqualTo(0));
      expect(status, greaterThan(sample));
      expect(telemetry, greaterThan(status));
    });

    test('Eco consumes authoritative native processing dimensions', () {
      final sample = source.indexOf('Future<void> _sampleAnime4kEco()');
      expect(sample, greaterThanOrEqualTo(0));
      expect(
        source.indexOf('width: telemetry.inputWidth', sample),
        greaterThan(sample),
      );
      expect(
        source.indexOf('height: telemetry.inputHeight', sample),
        greaterThan(sample),
      );
      expect(
        source.indexOf('width: telemetry.processingWidth', sample),
        greaterThan(sample),
      );
      expect(
        source.indexOf('height: telemetry.processingHeight', sample),
        greaterThan(sample),
      );
      expect(source, isNot(contains("getProperty('dwidth')")));
      expect(source, isNot(contains("getProperty('dheight')")));
    });

    test('runtime failure restores the resolved mpv fallback instead of faking ready', () {
      final sample = source.indexOf('Future<void> _sampleAnime4kEco()');
      expect(sample, greaterThanOrEqualTo(0));
      expect(
        source.indexOf(
          'metalState != Anime4kNativeMetalState.ready',
          sample,
        ),
        greaterThan(sample),
      );
      expect(
        source.indexOf('await applyAnime4kShaders()', sample),
        greaterThan(sample),
      );
    });

    test('Eco publishes diagnostics and clears stale fallback state', () {
      expect(source, contains('final anime4kDiagnosticsProvider'));
      expect(
        source,
        contains('_publishAnime4kPerformanceSnapshot(decision.snapshot)'),
      );

      // The fallback accepts an optional NativePlayer so HDR can fail closed
      // before base Metal configuration while Eco can still reuse the same
      // exact mpv restore path after a runtime failure.
      final fallback = source.indexOf(
        'Future<void> _applyResolvedMpvFallback({NativePlayer? platform})',
      );
      expect(fallback, greaterThanOrEqualTo(0));
      expect(
        source.indexOf('_publishAnime4kPerformanceSnapshot(null)', fallback),
        greaterThan(fallback),
      );

      final disable = source.indexOf('void _disableAnime4kMetal()');
      expect(disable, greaterThanOrEqualTo(0));
      expect(
        source.indexOf('_publishAnime4kPerformanceSnapshot(null)', disable),
        greaterThan(disable),
      );
    });

    test('Eco uses requested quality as a ceiling and applies native bypass explicitly', () {
      expect(source, contains('settings.anime4kEcoEnabled'));
      expect(source, contains('Anime4kEcoGovernor'));
      expect(source, contains('decision.plan.effectiveQuality'));
      expect(
        source,
        contains('metalBridge.setBypass(handle: handle, bypass:'),
      );
    });

    test('Anime4K settings changes reapply the active playback session', () {
      expect(source, contains('ref.listen(playerSettingsProvider'));
      expect(source, contains('_anime4kSettingsChanged'));
      expect(source, contains('unawaited(applyAnime4kShaders())'));
    });

    test('Eco timer is cancelled with native teardown', () {
      final disable = source.indexOf('void _disableAnime4kMetal()');
      expect(disable, greaterThanOrEqualTo(0));
      expect(
        source.indexOf('_anime4kEcoTimer?.cancel()', disable),
        greaterThan(disable),
      );
    });
  });
}
