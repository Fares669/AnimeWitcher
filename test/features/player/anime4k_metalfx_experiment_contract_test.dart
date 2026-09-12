import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K MetalFX Eco experiment isolation', () {
    test('MetalFX adapter is isolated and conditionally imported', () {
      final adapter = File(
        'native/anime4k_metal/Anime4KMetalFXScaler.swift',
      );

      expect(adapter.existsSync(), isTrue);
      final source = adapter.readAsStringSync();
      expect(source, contains('#if canImport(MetalFX)'));
      expect(source, contains('import MetalFX'));
      expect(source, contains('MTLFXSpatialScalerDescriptor'));
      expect(source, contains('isAvailable'));
    });

    test('full Anime4K remains the runtime default', () {
      final runtime = File(
        'native/anime4k_metal/Anime4KMetalRuntime.swift',
      ).readAsStringSync();

      expect(runtime, contains('enum Anime4KAppleUpscaleStrategy'));
      expect(runtime, contains('case fullAnime4K'));
      expect(runtime, contains('case restoreDenoiseMetalFXSpatial'));
      expect(
        runtime,
        contains(
          'upscaleStrategy: Anime4KAppleUpscaleStrategy = .fullAnime4K',
        ),
      );
    });

    test('experimental MetalFX strategy is explicit and capability gated', () {
      final runtime = File(
        'native/anime4k_metal/Anime4KMetalRuntime.swift',
      ).readAsStringSync();

      expect(runtime, contains('Anime4KMetalFXScaler'));
      expect(runtime, contains('.restoreDenoiseMetalFXSpatial'));
      expect(runtime, contains('isAvailable'));
      expect(
        runtime,
        isNot(
          contains(
            'upscaleStrategy: Anime4KAppleUpscaleStrategy = .restoreDenoiseMetalFXSpatial',
          ),
        ),
      );
    });

    test('adapter is shipped by CocoaPods patch and native CI contracts', () {
      final patch = File(
        'scripts/anime4k_media_kit_patch.rb',
      ).readAsStringSync();
      final workflow = File(
        '.github/workflows/anime4k-platform-build.yml',
      ).readAsStringSync();

      expect(patch, contains('Anime4KMetalFXScaler.swift'));
      expect(workflow, contains('native/anime4k_metal/Anime4KMetalFXScaler.swift'));
    });

    test('benchmark toggle is hidden, debug-only, and restricted to Eco', () {
      final controller = File(
        'lib/features/player/presentation/player_controller_base.dart',
      ).readAsStringSync();
      final bridge = File(
        'lib/features/player/data/anime4k_metal_bridge.dart',
      ).readAsStringSync();
      final capi = File(
        'native/anime4k_metal/Anime4KMetalCAPI.swift',
      ).readAsStringSync();

      expect(
        controller,
        contains("bool.fromEnvironment('ANIME4K_METALFX_EXPERIMENT')"),
      );
      expect(controller, contains('settings?.anime4kEcoEnabled ?? false'));
      expect(controller, contains("'restoreDenoiseMetalFXSpatial'"));
      expect(controller, contains("'fullAnime4K'"));
      expect(bridge, contains("'upscaleStrategy': upscaleStrategy"));
      expect(capi, contains('upscaleStrategy'));
      expect(capi, contains('Anime4KAppleUpscaleStrategy'));
    });

    test('experiment removes Anime4K upscale stages before MetalFX', () {
      final runtime = File(
        'native/anime4k_metal/Anime4KMetalRuntime.swift',
      ).readAsStringSync();

      expect(runtime, contains('experimentalShaderPaths'));
      expect(runtime, contains('Anime4K_Upscale_CNN_x2_'));
      expect(runtime, contains('Anime4K_Upscale_Denoise_CNN_x2_'));
      expect(runtime, contains('Anime4K_AutoDownscalePre_x2.glsl'));
      expect(runtime, contains('Anime4K_AutoDownscalePre_x4.glsl'));
      expect(runtime, contains('Anime4K_Restore_CNN_'));
    });
  });
}
