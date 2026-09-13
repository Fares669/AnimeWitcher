// Triggers the one-shot cleanup migration after its RED contract was staged.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K simplified settings contract', () {
    test('Eco, MetalFX, and the user-facing performance log are removed', () {
      final settings = File(
        'lib/features/settings/presentation/player_settings_provider.dart',
      ).readAsStringSync();
      final dialog = File(
        'lib/features/settings/presentation/widgets/anime4k_dialog.dart',
      ).readAsStringSync();
      final controller = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();
      final ffi = File(
        'lib/features/player/data/anime4k_metal_ffi.dart',
      ).readAsStringSync();
      final runtime = File(
        'native/anime4k_metal/Anime4KMetalRuntime.swift',
      ).readAsStringSync();
      final capi = File(
        'native/anime4k_metal/Anime4KMetalCAPI.swift',
      ).readAsStringSync();

      expect(settings, isNot(contains('anime4kEcoEnabled')));
      expect(settings, isNot(contains('anime4kMetalFxEnabled')));
      expect(dialog, isNot(contains('Eco / Auto')));
      expect(dialog, isNot(contains('MetalFX (experimental)')));
      expect(dialog, isNot(contains('anime4k_performance_log.dart')));
      expect(dialog, isNot(contains('Performance log')));
      expect(controller, isNot(contains('anime4kEcoEnabled')));
      expect(controller, isNot(contains('anime4kMetalFxEnabled')));
      expect(controller, isNot(contains('anime4kPerformanceLogProvider')));
      expect(ffi, isNot(contains('setBypass')));
      expect(ffi, isNot(contains('upscaleStrategy')));
      expect(runtime, isNot(contains('Anime4KMetalFXScaler')));
      expect(runtime, isNot(contains('restoreDenoiseMetalFXSpatial')));
      expect(capi, isNot(contains('setBypass')));
      expect(capi, isNot(contains('upscaleStrategy')));

      expect(
        File('lib/features/player/data/anime4k_performance_log.dart').existsSync(),
        isFalse,
      );
      expect(
        File('lib/features/player/data/anime4k_eco_governor.dart').existsSync(),
        isFalse,
      );
      expect(
        File('native/anime4k_metal/Anime4KMetalFXScaler.swift').existsSync(),
        isFalse,
      );
    });
  });

  group('Anime4K sample preview asset copy', () {
    test('copies exactly the ByteData view rather than the whole backing buffer', () {
      final source = File(
        'lib/features/player/presentation/widgets/anime4k_sample_preview.dart',
      ).readAsStringSync();

      expect(source, contains('bytes.offsetInBytes'));
      expect(source, contains('bytes.lengthInBytes'));
      expect(source, isNot(contains('bytes.buffer.asUint8List(),')));
    });
  });
}
