import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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

String _digestOnWorker(File file, bool useRust) {
  if (useRust && !file.path.contains('\u0000')) {
    final result = _tryRustFileDigest(file.path);
    if (result != null) return result;
  }
  return _bufferedDigest(file);
}

// This runs only in the worker. Async file reads allocate a fresh external
// buffer for each chunk and use the VM I/O pool even though nothing on this
// isolate can usefully run while the file is being hashed.
String _bufferedDigest(File file) {
  final buffer = Uint8List(256 * 1024);
  final digest = _DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  final input = file.openSync();
  try {
    while (true) {
      final read = input.readIntoSync(buffer);
      if (read == 0) break;
      hash.add(
        read == buffer.length ? buffer : Uint8List.sublistView(buffer, 0, read),
      );
    }
  } finally {
    input.closeSync();
  }
  hash.close();
  return digest.value.toString();
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest digest) => value = digest;

  @override
  void close() {}
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
