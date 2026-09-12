import 'dart:convert';

import 'anime4k_performance.dart';

/// Thin, testable contract over the Apple native Anime4K Metal C API.
///
/// The concrete FFI binding lives separately so routing/payload behavior can be
/// verified on every CI platform without loading Apple symbols.
abstract class Anime4kMetalNativeBindings {
  int configure(int handle, String configurationJson);

  int status(int handle);

  /// Enables/disables temporary Eco pass-through without destroying the
  /// configured runtime. Returns 1 on success and 0 when unsupported/invalid.
  int setBypass(int handle, bool bypass);

  /// Returns a small UTF-8 JSON snapshot for one player, or null when the
  /// optional telemetry symbol is unavailable. Telemetry must never decide
  /// whether the renderer itself can run.
  String? telemetry(int handle);

  void disable(int handle);
}

class Anime4kMetalTelemetry {
  const Anime4kMetalTelemetry({
    required this.averageFrameTimeMs,
    required this.p95FrameTimeMs,
    required this.processedFrames,
    required this.lateOrDroppedFrames,
    required this.thermalLevel,
    required this.lowPowerMode,
  });

  final double averageFrameTimeMs;
  final double p95FrameTimeMs;
  final int processedFrames;
  final int lateOrDroppedFrames;
  final Anime4kThermalLevel thermalLevel;
  final bool lowPowerMode;
}

/// Serializes one player's resolved Anime4K pipeline for the native Metal
/// runtime and maps native status values into the fail-closed Dart state used
/// by backend routing.
class Anime4kMetalBridge {
  Anime4kMetalBridge({required Anime4kMetalNativeBindings bindings})
    : _bindings = bindings;

  final Anime4kMetalNativeBindings _bindings;

  Anime4kNativeMetalState configure({
    required int handle,
    required List<String> shaderPaths,
    required String pipelineHash,
    required Anime4kProcessingDimensions source,
    required Anime4kProcessingDimensions output,
    String precision = 'mixedFP16',
  }) {
    if (handle <= 0 ||
        shaderPaths.isEmpty ||
        pipelineHash.isEmpty ||
        source.width <= 0 ||
        source.height <= 0 ||
        output.width <= 0 ||
        output.height <= 0) {
      return Anime4kNativeMetalState.failed;
    }

    try {
      final payload = jsonEncode(<String, Object>{
        'shaderPaths': List<String>.unmodifiable(shaderPaths),
        'pipelineHash': pipelineHash,
        'sourceWidth': source.width,
        'sourceHeight': source.height,
        'outputWidth': output.width,
        'outputHeight': output.height,
        'precision': precision,
      });
      return _stateFromNative(_bindings.configure(handle, payload));
    } catch (_) {
      return Anime4kNativeMetalState.failed;
    }
  }

  Anime4kNativeMetalState status({required int handle}) {
    if (handle <= 0) return Anime4kNativeMetalState.failed;
    try {
      return _stateFromNative(_bindings.status(handle));
    } catch (_) {
      return Anime4kNativeMetalState.failed;
    }
  }

  bool setBypass({required int handle, required bool bypass}) {
    if (handle <= 0) return false;
    try {
      return _bindings.setBypass(handle, bypass) == 1;
    } catch (_) {
      // Temporary Eco bypass is an optimization/safety control, not a reason
      // to crash playback. Callers can fail closed to their existing route.
      return false;
    }
  }

  Anime4kMetalTelemetry? telemetry({required int handle}) {
    if (handle <= 0) return null;
    try {
      final raw = _bindings.telemetry(handle);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final average = decoded['averageFrameTimeMs'];
      final p95 = decoded['p95FrameTimeMs'];
      final processed = decoded['processedFrames'];
      final lateOrDropped = decoded['lateOrDroppedFrames'];
      final thermal = decoded['thermalLevel'];
      final lowPower = decoded['lowPowerMode'];
      if (average is! num ||
          p95 is! num ||
          processed is! num ||
          lateOrDropped is! num ||
          thermal is! String ||
          lowPower is! bool) {
        return null;
      }

      final thermalLevel = switch (thermal.trim().toLowerCase()) {
        'nominal' => Anime4kThermalLevel.nominal,
        'fair' => Anime4kThermalLevel.fair,
        'serious' => Anime4kThermalLevel.serious,
        'critical' => Anime4kThermalLevel.critical,
        _ => null,
      };
      if (thermalLevel == null ||
          average.isNegative ||
          p95.isNegative ||
          processed.isNegative ||
          lateOrDropped.isNegative) {
        return null;
      }

      return Anime4kMetalTelemetry(
        averageFrameTimeMs: average.toDouble(),
        p95FrameTimeMs: p95.toDouble(),
        processedFrames: processed.toInt(),
        lateOrDroppedFrames: lateOrDropped.toInt(),
        thermalLevel: thermalLevel,
        lowPowerMode: lowPower,
      );
    } catch (_) {
      // Diagnostics/adaptation are optional. Bad telemetry must not interfere
      // with video playback or force a backend switch.
      return null;
    }
  }

  void disable({required int handle}) {
    if (handle <= 0) return;
    try {
      _bindings.disable(handle);
    } catch (_) {
      // Playback teardown and fallback must never fail because the optional
      // Metal backend is unavailable. The mpv path remains authoritative.
    }
  }
}

Anime4kNativeMetalState _stateFromNative(int value) {
  switch (value) {
    case 0:
      return Anime4kNativeMetalState.unavailable;
    case 1:
      return Anime4kNativeMetalState.ready;
    case 2:
      return Anime4kNativeMetalState.failed;
    case 3:
      return Anime4kNativeMetalState.unsupportedHdr;
    case 4:
      // Native `disabled` is intentionally represented as unavailable on the
      // Dart side: both states mean Metal must not own Anime4K frames.
      return Anime4kNativeMetalState.unavailable;
    default:
      return Anime4kNativeMetalState.failed;
  }
}
