import 'dart:convert';

import 'package:animewitcher/features/player/data/anime4k_metal_bridge.dart';
import 'package:animewitcher/features/player/data/anime4k_performance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K Metal Dart bridge', () {
    test('serializes a per-player configuration and maps ready status', () {
      final bindings = _FakeBindings(configureResult: 1);
      final bridge = Anime4kMetalBridge(bindings: bindings);

      final state = bridge.configure(
        handle: 0xA41E4,
        shaderPaths: const ['/tmp/a.glsl', '/tmp/b.glsl'],
        pipelineHash: 'pipeline-hash',
        source: const Anime4kProcessingDimensions(width: 1280, height: 720),
        output: const Anime4kProcessingDimensions(width: 1920, height: 1080),
      );

      expect(state, Anime4kNativeMetalState.ready);
      expect(bindings.configureHandle, 0xA41E4);
      final payload = jsonDecode(bindings.configureJson!) as Map<String, dynamic>;
      expect(payload['shaderPaths'], ['/tmp/a.glsl', '/tmp/b.glsl']);
      expect(payload['pipelineHash'], 'pipeline-hash');
      expect(payload['sourceWidth'], 1280);
      expect(payload['sourceHeight'], 720);
      expect(payload['outputWidth'], 1920);
      expect(payload['outputHeight'], 1080);
      expect(payload['precision'], 'mixedFP16');
    });

    test('maps native failure states without throwing into playback control', () {
      final failed = Anime4kMetalBridge(
        bindings: _FakeBindings(configureResult: 2),
      );
      final unavailable = Anime4kMetalBridge(
        bindings: _FakeBindings(configureResult: 0),
      );
      final hdr = Anime4kMetalBridge(
        bindings: _FakeBindings(configureResult: 3),
      );

      Anime4kNativeMetalState configure(Anime4kMetalBridge bridge) {
        return bridge.configure(
          handle: 7,
          shaderPaths: const ['/tmp/a.glsl'],
          pipelineHash: 'x',
          source: const Anime4kProcessingDimensions(width: 8, height: 8),
          output: const Anime4kProcessingDimensions(width: 8, height: 8),
        );
      }

      expect(configure(failed), Anime4kNativeMetalState.failed);
      expect(configure(unavailable), Anime4kNativeMetalState.unavailable);
      expect(configure(hdr), Anime4kNativeMetalState.unsupportedHdr);
    });

    test('queries and disables the exact player handle', () {
      final bindings = _FakeBindings(statusResult: 2);
      final bridge = Anime4kMetalBridge(bindings: bindings);

      expect(bridge.status(handle: 99), Anime4kNativeMetalState.failed);
      expect(bindings.statusHandle, 99);

      bridge.disable(handle: 99);
      expect(bindings.disableHandle, 99);
    });

    test('temporary Eco bypass uses the exact player handle and fails closed', () {
      final bindings = _FakeBindings(bypassResult: 1);
      final bridge = Anime4kMetalBridge(bindings: bindings);

      expect(bridge.setBypass(handle: 41, bypass: true), isTrue);
      expect(bindings.bypassHandle, 41);
      expect(bindings.bypassValue, isTrue);

      final failed = Anime4kMetalBridge(
        bindings: _FakeBindings(bypassResult: 0),
      );
      expect(failed.setBypass(handle: 41, bypass: false), isFalse);
    });

    test('invalid native status fails closed instead of enabling Metal', () {
      final bridge = Anime4kMetalBridge(
        bindings: _FakeBindings(configureResult: 999),
      );

      final state = bridge.configure(
        handle: 1,
        shaderPaths: const ['/tmp/a.glsl'],
        pipelineHash: 'x',
        source: const Anime4kProcessingDimensions(width: 8, height: 8),
        output: const Anime4kProcessingDimensions(width: 8, height: 8),
      );

      expect(state, Anime4kNativeMetalState.failed);
    });

    test('decodes per-player native telemetry for the Eco governor', () {
      final bindings = _FakeBindings(
        telemetryJson: jsonEncode(<String, Object>{
          'averageFrameTimeMs': 8.25,
          'p95FrameTimeMs': 12.5,
          'processedFrames': 120,
          'lateOrDroppedFrames': 3,
          'thermalLevel': 'fair',
          'lowPowerMode': true,
        }),
      );
      final bridge = Anime4kMetalBridge(bindings: bindings);

      final telemetry = bridge.telemetry(handle: 77);

      expect(bindings.telemetryHandle, 77);
      expect(telemetry, isNotNull);
      expect(telemetry!.averageFrameTimeMs, 8.25);
      expect(telemetry.p95FrameTimeMs, 12.5);
      expect(telemetry.processedFrames, 120);
      expect(telemetry.lateOrDroppedFrames, 3);
      expect(telemetry.thermalLevel, Anime4kThermalLevel.fair);
      expect(telemetry.lowPowerMode, isTrue);
    });

    test('malformed native telemetry fails closed', () {
      final bridge = Anime4kMetalBridge(
        bindings: _FakeBindings(telemetryJson: '{not-json'),
      );

      expect(bridge.telemetry(handle: 5), isNull);
    });
  });
}

class _FakeBindings implements Anime4kMetalNativeBindings {
  _FakeBindings({
    this.configureResult = 1,
    this.statusResult = 1,
    this.bypassResult = 1,
    this.telemetryJson,
  });

  final int configureResult;
  final int statusResult;
  final int bypassResult;
  final String? telemetryJson;
  int? configureHandle;
  String? configureJson;
  int? statusHandle;
  int? disableHandle;
  int? telemetryHandle;
  int? bypassHandle;
  bool? bypassValue;

  @override
  int configure(int handle, String configurationJson) {
    configureHandle = handle;
    configureJson = configurationJson;
    return configureResult;
  }

  @override
  int status(int handle) {
    statusHandle = handle;
    return statusResult;
  }

  @override
  int setBypass(int handle, bool bypass) {
    bypassHandle = handle;
    bypassValue = bypass;
    return bypassResult;
  }

  @override
  String? telemetry(int handle) {
    telemetryHandle = handle;
    return telemetryJson;
  }

  @override
  void disable(int handle) {
    disableHandle = handle;
  }
}
