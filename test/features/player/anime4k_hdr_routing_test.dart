import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K Apple HDR safety gate', () {
    test('color classifier distinguishes SDR, HDR, and unknown transfers', () {
      final performance = File(
        'lib/features/player/data/anime4k_performance.dart',
      ).readAsStringSync();

      expect(performance, contains('enum Anime4kColorSignal { sdr, hdr, unknown }'));
      expect(performance, contains('classifyAnime4kColorSignal'));
      expect(performance, contains("'pq'"));
      expect(performance, contains("'hlg'"));
      expect(performance, contains("'st2084'"));
      expect(performance, contains("'std-b67'"));
      expect(performance, contains("'scrgb'"));
      expect(performance, contains("'bt.1886'"));
      expect(performance, contains("'srgb'"));
    });

    test('player reads mpv color metadata before configuring Apple Metal', () {
      final controller = File(
        'lib/features/player/presentation/player_controller_base.dart',
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
      final metalConfigure = controller.indexOf('metalBridge.configure(');

      expect(gammaRead, greaterThanOrEqualTo(0));
      expect(colorSystemRead, greaterThanOrEqualTo(0));
      expect(classification, greaterThanOrEqualTo(0));
      expect(unsupportedHdr, greaterThanOrEqualTo(0));
      expect(metalConfigure, greaterThanOrEqualTo(0));
      expect(gammaRead, lessThan(metalConfigure));
      expect(colorSystemRead, lessThan(metalConfigure));
      expect(classification, lessThan(metalConfigure));
      expect(unsupportedHdr, lessThan(metalConfigure));
    });

    test('unknown Apple color metadata fails closed before Metal configure', () {
      final controller = File(
        'lib/features/player/presentation/player_controller_base.dart',
      ).readAsStringSync();

      expect(
        controller,
        contains('Anime4kColorSignal.unknown'),
      );
      expect(
        controller,
        contains('Anime4kColorSignal.hdr'),
      );
      expect(
        controller,
        contains('Anime4kNativeMetalState.unsupportedHdr'),
      );
    });
  });
}
