import 'dart:io';

import 'package:animewitcher/features/player/data/anime4k_color_signal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K Apple HDR safety gate', () {
    test('color classifier distinguishes SDR, HDR, and unknown transfers', () {
      for (final transfer in <String>[
        'bt.1886',
        'srgb',
        'gamma2.2',
        'gamma2.4',
      ]) {
        expect(
          classifyAnime4kColorSignal(transfer: transfer),
          Anime4kColorSignal.sdr,
          reason: transfer,
        );
      }

      for (final transfer in <String>[
        'pq',
        'hlg',
        'st2084',
        'std-b67',
        'scrgb',
      ]) {
        expect(
          classifyAnime4kColorSignal(transfer: transfer),
          Anime4kColorSignal.hdr,
          reason: transfer,
        );
      }

      expect(
        classifyAnime4kColorSignal(colorSystem: 'scrgb'),
        Anime4kColorSignal.hdr,
      );
      expect(
        classifyAnime4kColorSignal(transfer: null, colorSystem: 'bt.2020-ncl'),
        Anime4kColorSignal.unknown,
      );
      expect(
        classifyAnime4kColorSignal(transfer: 'log', colorSystem: 'bt.709'),
        Anime4kColorSignal.unknown,
      );
    });

    test('Apple wrapper reads color metadata before base Metal configure', () {
      final controller = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();

      final gammaRead = controller.indexOf(
        "getProperty('video-params/gamma')",
      );
      final colorSystemRead = controller.indexOf(
        "getProperty('video-params/colormatrix')",
      );
      final classification = controller.indexOf('classifyAnime4kColorSignal');
      final unsupportedHdr = controller.indexOf(
        'Anime4kNativeMetalState.unsupportedHdr',
      );
      final baseApply = controller.indexOf('await super.applyAnime4kShaders()');

      expect(gammaRead, greaterThanOrEqualTo(0));
      expect(colorSystemRead, greaterThanOrEqualTo(0));
      expect(classification, greaterThanOrEqualTo(0));
      expect(unsupportedHdr, greaterThanOrEqualTo(0));
      expect(baseApply, greaterThanOrEqualTo(0));
      expect(gammaRead, lessThan(baseApply));
      expect(colorSystemRead, lessThan(baseApply));
      expect(classification, lessThan(baseApply));
      expect(unsupportedHdr, lessThan(baseApply));
    });

    test('HDR and unknown metadata fail closed through exact mpv fallback', () {
      final controller = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();

      expect(controller, contains('Anime4kColorSignal.unknown'));
      expect(controller, contains('Anime4kColorSignal.sdr'));
      expect(
        controller,
        contains('Anime4kNativeMetalState.unsupportedHdr'),
      );
      expect(controller, contains('_applyResolvedMpvFallback(platform: platform)'));
      expect(controller, contains("setProperty('glsl-shaders', pipeline.value)"));
      expect(controller, contains("getProperty('current-vo')"));
      expect(controller, contains("getProperty('gpu-dumb-mode')"));
    });

    test('HDR fallback disables native Metal using the real player handle', () {
      final controller = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();

      expect(controller, contains('final resolvedHandle = await nativePlatform.handle'));
      expect(controller, contains('metalBridge.disable(handle: handle)'));
    });
  });
}
