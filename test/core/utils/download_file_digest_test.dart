import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:animewitcher/core/utils/download_file_digest.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

@Native<Int32 Function(Pointer<Utf8>, Pointer<Uint8>)>(
  symbol: 'animewitcher_download_sha256_v1',
  assetId: 'package:animewitcher/core/utils/download_file_digest.dart',
)
external int _probeNative(Pointer<Utf8> path, Pointer<Uint8> output);

class _ObservedFile implements File {
  const _ObservedFile(this.path, this.observations);

  @override
  final String path;
  final SendPort observations;

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) {
    return _ObservedAccessFile(File(path).openSync(mode: mode), observations);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ObservedAccessFile implements RandomAccessFile {
  _ObservedAccessFile(this.delegate, this.observations);

  final RandomAccessFile delegate;
  final SendPort observations;
  List<int>? _firstBuffer;

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    _firstBuffer ??= buffer;
    final read = delegate.readIntoSync(buffer, start, end);
    observations.send((
      Isolate.current.controlPort,
      identical(buffer, _firstBuffer),
      buffer.length,
      read,
    ));
    return read;
  }

  @override
  void closeSync() => delegate.closeSync();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('aw_hash_'));
  tearDown(() async => root.delete(recursive: true));

  test(
    'publication digest matches independent vectors and file boundaries',
    () async {
      final path = File('${root.path}/ملف حلقة.bin');
      final data = Uint8List(256 * 1024 + 1);
      for (var i = 0; i < data.length; i++) {
        data[i] = (i * 171 + (i >> 3)) & 255;
      }
      for (final size in [
        0,
        1,
        55,
        56,
        64,
        65535,
        65536,
        262143,
        262144,
        data.length,
      ]) {
        final bytes = Uint8List.sublistView(data, 0, size);
        await path.writeAsBytes(bytes);
        expect(
          await downloadFileDigest(path),
          sha256.convert(bytes).toString(),
          reason: '$size bytes',
        );
      }
      await path.writeAsString('abc');
      expect(
        await downloadFileDigest(path),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    },
  );

  test('missing source retains the Dart filesystem error', () async {
    await expectLater(
      downloadFileDigest(File('${root.path}/missing.part')),
      throwsA(isA<FileSystemException>()),
    );
  });

  if (!const bool.fromEnvironment('ANIMEWITCHER_RUST_DOWNLOAD_SHA256')) {
    test(
      'reuses one bounded read buffer on an isolate distinct from the UI',
      () async {
        final bytes = Uint8List(512 * 1024 + 13);
        bytes[bytes.length - 1] = 251;
        final file = await File('${root.path}/worker.bin').writeAsBytes(bytes);
        final observations = ReceivePort();
        try {
          final reads = observations
              .cast<(SendPort, bool, int, int)>()
              .take(4)
              .toList();
          final digest = await downloadFileDigest(
            _ObservedFile(file.path, observations.sendPort),
          );
          expect(digest, sha256.convert(bytes).toString());
          final seen = await reads.timeout(const Duration(seconds: 2));
          expect(seen.map((read) => read.$4), [256 * 1024, 256 * 1024, 13, 0]);
          for (final (worker, reused, capacity, _) in seen) {
            expect(worker, isNot(Isolate.current.controlPort));
            expect(reused, isTrue);
            expect(capacity, 256 * 1024);
          }
        } finally {
          observations.close();
        }
      },
    );
  }

  if (const bool.fromEnvironment('ANIMEWITCHER_EXPECT_RUST_DOWNLOAD_SHA256')) {
    test(
      'opt-in build actually exports the locked Rust implementation',
      () async {
        expect(Abi.current(), Abi.linuxX64);
        final path = await File('${root.path}/known.txt').writeAsString('abc');
        using((arena) {
          final output = arena<Uint8>(32);
          expect(
            _probeNative(path.path.toNativeUtf8(allocator: arena), output),
            0,
          );
          expect(
            Digest(output.asTypedList(32)).toString(),
            sha256.convert('abc'.codeUnits).toString(),
          );
        });
      },
    );
  }
}
