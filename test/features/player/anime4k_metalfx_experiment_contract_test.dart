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
  });
}
