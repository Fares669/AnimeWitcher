import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K Apple frame publication', () {
    test('final-writes into the media_kit surface without a second Metal blit', () {
      final runtime = File(
        'native/anime4k_metal/Anime4KMetalRuntime.swift',
      ).readAsStringSync();
      final bridge = File(
        'native/anime4k_metal/Anime4KMediaKitBridge.swift',
      ).readAsStringSync();

      expect(
        runtime,
        contains('destinationPixelBuffer:'),
        reason:
            'The runtime needs an explicit destination so its final copy can write directly into media_kit ownership.',
      );
      expect(
        bridge,
        contains('destinationPixelBuffer: pixelBuffer'),
        reason:
            'The media_kit CVPixelBuffer must be the runtime final destination.',
      );
      expect(
        bridge,
        isNot(contains('copyProcessedFrame(')),
        reason:
            'A second full-frame Metal blit delays publication and can starve media_kit triple buffering.',
      );
      expect(
        bridge,
        isNot(contains('copyQueue')),
        reason:
            'The hot publication path must not own a second Metal command queue.',
      );
    });
  });
}
