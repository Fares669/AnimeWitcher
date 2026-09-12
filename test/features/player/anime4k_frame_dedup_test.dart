import 'dart:io';

import 'package:animewitcher/features/player/data/anime4k_metal_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class _TelemetryBindings implements Anime4kMetalNativeBindings {
  _TelemetryBindings(this.payload);

  final String payload;

  @override
  int configure(int handle, String configurationJson) => 1;

  @override
  void disable(int handle) {}

  @override
  int setBypass(int handle, bool bypass) => 1;

  @override
  int status(int handle) => 1;

  @override
  String? telemetry(int handle) => payload;
}

void main() {
  group('Anime4K frame deduplication', () {
    test('native duplicate count is decoded into Dart telemetry', () {
      final bridge = Anime4kMetalBridge(
        bindings: _TelemetryBindings('''
          {
            "averageFrameTimeMs": 3.5,
            "p95FrameTimeMs": 4.5,
            "processedFrames": 11,
            "skippedDuplicateFrames": 7,
            "lateOrDroppedFrames": 2,
            "inputWidth": 1920,
            "inputHeight": 1080,
            "processingWidth": 1170,
            "processingHeight": 658,
            "thermalLevel": "nominal",
            "lowPowerMode": false
          }
        '''),
      );

      final dynamic telemetry = bridge.telemetry(handle: 123);
      expect(telemetry, isNotNull);
      expect(telemetry.skippedDuplicateFrames, 7);
      expect(telemetry.processedFrames, 11);
      expect(telemetry.lateOrDroppedFrames, 2);
    });

    test('Eco snapshot forwards native duplicate count instead of zero', () {
      final governor = File(
        'lib/features/player/data/anime4k_eco_governor.dart',
      ).readAsStringSync();

      expect(
        governor,
        contains('skippedDuplicateFrames: telemetry.skippedDuplicateFrames'),
      );
      expect(
        governor,
        isNot(contains('skippedDuplicateFrames: 0')),
      );
    });

    test('C API exposes duplicate counter from runtime telemetry', () {
      final capi = File(
        'native/anime4k_metal/Anime4KMetalCAPI.swift',
      ).readAsStringSync();

      expect(
        capi,
        contains('"skippedDuplicateFrames": runtime.skippedDuplicateFrames'),
      );
    });

    test('media_kit patch skips Anime4K when mpv reports no new frame', () {
      final patch = File(
        'scripts/anime4k_media_kit_patch.rb',
      ).readAsStringSync();

      expect(patch, contains('mpv_render_context_update(renderContext)'));
      expect(patch, contains('MPV_RENDER_UPDATE_FRAME'));
      expect(patch, contains('recordSkippedDuplicate'));
    });
  });
}
