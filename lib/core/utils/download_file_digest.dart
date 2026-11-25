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

/// Hashes off the caller's isolate so Dart's SHA-256 work cannot occupy the
/// Flutter UI isolate while the coordinator is waiting to publish the file.
Future<String> downloadFileDigest(File file) async {
  final useRust = _enableRust && Abi.current() == Abi.linuxX64;
  try {
    return await Isolate.run(() => _digestOnWorker(file, useRust));
  } on IsolateSpawnException {
    // Preserve publication and the original Dart error behavior if the
    // runtime cannot start a worker.
    return _streamDigest(file);
  }
}

Future<String> _digestOnWorker(File file, bool useRust) async {
  if (useRust && !file.path.contains('\u0000')) {
    final result = _tryRustFileDigest(file.path);
    if (result != null) return result;
  }
  return _streamDigest(file);
}

Future<String> _streamDigest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

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
