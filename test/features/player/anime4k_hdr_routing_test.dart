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
      final nonSdrGuard = controller.indexOf(
        'colorSignal != Anime4kColorSignal.sdr',
      );
      final baseApply = controller.indexOf('await super.applyAnime4kShaders()');

      expect(gammaRead, greaterThanOrEqualTo(0));
      expect(colorSystemRead, greaterThanOrEqualTo(0));
      expect(classification, greaterThanOrEqualTo(0));
      expect(nonSdrGuard, greaterThanOrEqualTo(0));
      expect(baseApply, greaterThanOrEqualTo(0));
      expect(gammaRead, lessThan(baseApply));
      expect(colorSystemRead, lessThan(baseApply));
      expect(classification, lessThan(baseApply));
      expect(nonSdrGuard, lessThan(baseApply));
    });

    test('HDR and unknown metadata fail closed through exact mpv fallback', () {
      final controller = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();

      expect(controller, contains('Anime4kColorSignal.unknown'));
      expect(controller, contains('colorSignal != Anime4kColorSignal.sdr'));
      expect(
        controller,
        contains('_applyResolvedMpvFallback(platform: platform)'),
      );
      expect(controller, contains("setProperty('glsl-shaders', pipeline.value)"));
      expect(controller, contains("getProperty('current-vo')"));
      expect(controller, contains("getProperty('gpu-dumb-mode')"));
    });

    test('HDR fallback disables native Metal using the real player handle', () {
      final controller = File(
        'lib/features/player/presentation/player_controller.dart',
      ).readAsStringSync();

      expect(controller, contains('final handle = await nativePlatform.handle'));
      expect(controller, contains('metalBridge.disable(handle: handle)'));
    });
  });

  group('Anime4K color metadata readiness', () {
    test('waits through transient unknown metadata until SDR is ready', () async {
      var reads = 0;
      final result = await waitForAnime4kColorSignal(
        maxAttempts: 5,
        retryDelay: Duration.zero,
        read: () async {
          reads++;
          return reads < 3
              ? Anime4kColorSignal.unknown
              : Anime4kColorSignal.sdr;
        },
      );

      expect(result, Anime4kColorSignal.sdr);
      expect(reads, 3);
    });

    test('returns HDR as soon as metadata becomes known', () async {
      var reads = 0;
      final result = await waitForAnime4kColorSignal(
        maxAttempts: 5,
        retryDelay: Duration.zero,
        read: () async {
          reads++;
          return reads == 1
              ? Anime4kColorSignal.unknown
              : Anime4kColorSignal.hdr;
        },
      );

      expect(result, Anime4kColorSignal.hdr);
      expect(reads, 2);
    });

    test('fails closed after bounded retries when metadata stays unknown', () async {
      var reads = 0;
      final result = await waitForAnime4kColorSignal(
        maxAttempts: 3,
        retryDelay: Duration.zero,
        read: () async {
          reads++;
          return Anime4kColorSignal.unknown;
        },
      );

      expect(result, Anime4kColorSignal.unknown);
      expect(reads, 3);
    });

    test('cancellation fails closed without another metadata read', () async {
      var reads = 0;
      final result = await waitForAnime4kColorSignal(
        maxAttempts: 5,
        retryDelay: Duration.zero,
        isCancelled: () => reads >= 1,
        read: () async {
          reads++;
          return Anime4kColorSignal.unknown;
        },
      );

      expect(result, Anime4kColorSignal.unknown);
      expect(reads, 1);
    });
  });
}
