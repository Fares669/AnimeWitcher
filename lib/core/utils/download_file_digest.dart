import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

const _enableRust = bool.fromEnvironment('ANIMEWITCHER_RUST_DOWNLOAD_SHA256');

@Native<Int32 Function(Pointer<Utf8>, Pointer<Uint8>)>(
  symbol: 'animewitcher_download_sha256_v1',
)
external int _rustFileDigest(Pointer<Utf8> path, Pointer<Uint8> output);

/// Keeps the existing streaming digest on every default or unsupported build.
Future<String> downloadFileDigest(File file) async {
  if (_enableRust && Abi.current() == Abi.linuxX64) {
    final path = file.path;
    if (!path.contains('\u0000')) {
      try {
        final result = await Isolate.run(() => _tryRustFileDigest(path));
        if (result != null) return result;
      } on IsolateSpawnException {
        // A worker could not be started; the streaming path remains available.
      }
    }
  }
  return (await sha256.bind(file.openRead()).first).toString();
}

String? _tryRustFileDigest(String path) {
  return using((arena) {
    final name = path.toNativeUtf8(allocator: arena);
    final output = arena<Uint8>(32);
    try {
      if (_rustFileDigest(name, output) != 0) return null;
      return Digest(output.asTypedList(32)).toString();
    } on ArgumentError {
      // A build may opt in at runtime without bundling the native asset.
      return null;
    } on UnsupportedError {
      return null;
    }
  });
}
