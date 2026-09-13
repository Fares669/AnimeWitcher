import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'anime4k_metal_bridge.dart';

typedef _ConfigureNative = Int32 Function(Uint64, Pointer<Utf8>);
typedef _ConfigureDart = int Function(int, Pointer<Utf8>);
typedef _ProcessPreviewNative = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _ProcessPreviewDart = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _StatusNative = Int32 Function(Uint64);
typedef _StatusDart = int Function(int);
typedef _SetBypassNative = Int32 Function(Uint64, Int32);
typedef _SetBypassDart = int Function(int, int);
typedef _TelemetryNative = Int32 Function(
  Uint64,
  Pointer<Uint8>,
  Int32,
);
typedef _TelemetryDart = int Function(int, Pointer<Uint8>, int);
typedef _DisableNative = Void Function(Uint64);
typedef _DisableDart = void Function(int);

/// FFI implementation for the symbols exported by the patched Apple
/// media_kit module. Creation is fail-safe so non-Apple platforms and builds
/// without the optional symbols continue on mpv GLSL unchanged.
class Anime4kMetalFfiBindings implements Anime4kMetalNativeBindings {
  Anime4kMetalFfiBindings._(DynamicLibrary library)
    : _configure = library.lookupFunction<_ConfigureNative, _ConfigureDart>(
        'animewitcher_anime4k_metal_configure',
      ),
      _processPreview = _tryLookupProcessPreview(library),
      _status = library.lookupFunction<_StatusNative, _StatusDart>(
        'animewitcher_anime4k_metal_status',
      ),
      _setBypass = _tryLookupSetBypass(library),
      _telemetry = _tryLookupTelemetry(library),
      _disable = library.lookupFunction<_DisableNative, _DisableDart>(
        'animewitcher_anime4k_metal_disable',
      );

  final _ConfigureDart _configure;
  final _ProcessPreviewDart? _processPreview;
  final _StatusDart _status;
  final _SetBypassDart? _setBypass;
  final _TelemetryDart? _telemetry;
  final _DisableDart _disable;

  static _ProcessPreviewDart? _tryLookupProcessPreview(DynamicLibrary library) {
    try {
      return library.lookupFunction<_ProcessPreviewNative, _ProcessPreviewDart>(
        'animewitcher_anime4k_metal_process_preview',
      );
    } catch (_) {
      // The one-shot settings preview was added after the playback C ABI.
      // Older Apple builds remain usable and simply take the mpv fallback.
      return null;
    }
  }

  static _SetBypassDart? _tryLookupSetBypass(DynamicLibrary library) {
    try {
      return library.lookupFunction<_SetBypassNative, _SetBypassDart>(
        'animewitcher_anime4k_metal_set_bypass',
      );
    } catch (_) {
      // The Eco bypass symbol is optional for compatibility with older Apple
      // builds. Returning 0 makes callers fail closed without disabling Metal.
      return null;
    }
  }

  static _TelemetryDart? _tryLookupTelemetry(DynamicLibrary library) {
    try {
      return library.lookupFunction<_TelemetryNative, _TelemetryDart>(
        'animewitcher_anime4k_metal_telemetry',
      );
    } catch (_) {
      // Telemetry was added after the core Metal C API. Keep it optional so a
      // missing diagnostics symbol never disables an otherwise working backend.
      return null;
    }
  }

  static Anime4kMetalFfiBindings? tryCreate() {
    if (!Platform.isIOS && !Platform.isMacOS) return null;
    try {
      return Anime4kMetalFfiBindings._(DynamicLibrary.process());
    } catch (_) {
      return null;
    }
  }

  @override
  int configure(int handle, String configurationJson) {
    final nativeJson = configurationJson.toNativeUtf8();
    try {
      return _configure(handle, nativeJson);
    } finally {
      malloc.free(nativeJson);
    }
  }

  /// Processes one still image through the native Apple runtime and writes a
  /// PNG result. Returns false when the optional symbol/runtime is unavailable
  /// so callers can fall back to the existing mpv preview path.
  bool processPreview({
    required String inputPath,
    required String outputPath,
    required List<String> shaderPaths,
    required String pipelineHash,
    String precision = 'mixedFP16',
    String upscaleStrategy = 'fullAnime4K',
  }) {
    final processPreview = _processPreview;
    if (processPreview == null ||
        inputPath.isEmpty ||
        outputPath.isEmpty ||
        shaderPaths.isEmpty ||
        pipelineHash.isEmpty) {
      return false;
    }

    final configurationJson = jsonEncode(<String, Object>{
      'shaderPaths': shaderPaths,
      'pipelineHash': pipelineHash,
      'precision': precision,
      'upscaleStrategy': upscaleStrategy,
    });
    final nativeInputPath = inputPath.toNativeUtf8();
    final nativeOutputPath = outputPath.toNativeUtf8();
    final nativeJson = configurationJson.toNativeUtf8();
    try {
      return processPreview(nativeInputPath, nativeOutputPath, nativeJson) == 1;
    } catch (_) {
      return false;
    } finally {
      malloc.free(nativeInputPath);
      malloc.free(nativeOutputPath);
      malloc.free(nativeJson);
    }
  }

  @override
  int status(int handle) => _status(handle);

  @override
  int setBypass(int handle, bool bypass) {
    final setBypass = _setBypass;
    if (setBypass == null) return 0;
    try {
      return setBypass(handle, bypass ? 1 : 0);
    } catch (_) {
      return 0;
    }
  }

  @override
  String? telemetry(int handle) {
    final telemetry = _telemetry;
    if (telemetry == null) return null;

    try {
      final nullBuffer = Pointer<Uint8>.fromAddress(0);
      final requiredBytes = telemetry(handle, nullBuffer, 0);
      if (requiredBytes <= 1 || requiredBytes > 64 * 1024) return null;

      final buffer = calloc<Uint8>(requiredBytes);
      try {
        final writtenBytes = telemetry(handle, buffer, requiredBytes);
        if (writtenBytes != requiredBytes) return null;
        return buffer.cast<Utf8>().toDartString();
      } finally {
        calloc.free(buffer);
      }
    } catch (_) {
      return null;
    }
  }

  @override
  void disable(int handle) => _disable(handle);
}
