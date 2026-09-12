import 'dart:convert';

import 'anime4k_performance.dart';

/// Thin, testable contract over the Apple native Anime4K Metal C API.
///
/// The concrete FFI binding lives separately so routing/payload behavior can be
/// verified on every CI platform without loading Apple symbols.
abstract class Anime4kMetalNativeBindings {
  int configure(int handle, String configurationJson);

  int status(int handle);

  void disable(int handle);
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
