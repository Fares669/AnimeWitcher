import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'anime4k_metal_bridge.dart';

typedef _ConfigureNative = Int32 Function(Uint64, Pointer<Utf8>);
typedef _ConfigureDart = int Function(int, Pointer<Utf8>);
typedef _StatusNative = Int32 Function(Uint64);
typedef _StatusDart = int Function(int);
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
      _status = library.lookupFunction<_StatusNative, _StatusDart>(
        'animewitcher_anime4k_metal_status',
      ),
      _telemetry = _tryLookupTelemetry(library),
      _disable = library.lookupFunction<_DisableNative, _DisableDart>(
        'animewitcher_anime4k_metal_disable',
      );

  final _ConfigureDart _configure;
  final _StatusDart _status;
  final _TelemetryDart? _telemetry;
  final _DisableDart _disable;

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

  @override
  int status(int handle) => _status(handle);

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
