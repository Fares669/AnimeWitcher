import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/download_integrity_verifier_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const verifier = DownloadIntegrityVerifierV2();
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('download-integrity-v2-');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  final textArtifacts = <String, String>{
    'hls-playlist': '\uFEFF \n#EXTM3U\nhttps://example.invalid/video.ts\n',
    'dash-manifest': '<?xml version="1.0"?><MPD><Period/></MPD>',
    'html-page': '<!doctype html><html><body>Login</body></html>',
  };

  for (final entry in textArtifacts.entries) {
    test(
      'new-transfer opt-in rejects ${entry.key} with matched size',
      () async {
        final bytes = utf8.encode(entry.value);
        final file = File('${temp.path}/video.mp4');
        await file.writeAsBytes(bytes);

        final result = await verifier.verify(
          file,
          expectedBytes: bytes.length,
          rejectNonVideoPayload: true,
        );

        expect(result.isValid, isFalse);
        expect(result.reason, entry.key);
        expect(result.bytes, isNull);
        expect(await file.readAsBytes(), bytes);
      },
    );

    test(
      'default keeps existing ${entry.key} byte-integrity semantics',
      () async {
        final bytes = utf8.encode(entry.value);
        final file = File('${temp.path}/existing.mp4');
        await file.writeAsBytes(bytes);

        final result = await verifier.verify(file, expectedBytes: bytes.length);

        expect(result.isValid, isTrue);
        expect(result.bytes, bytes.length);
        expect(await file.readAsBytes(), bytes);
      },
    );
  }

  test(
    'missing, empty, and size mismatch take precedence over payload',
    () async {
      final file = File('${temp.path}/video.mp4');
      expect(
        (await verifier.verify(file, rejectNonVideoPayload: true)).reason,
        'missing',
      );
      await file.create();
      expect(
        (await verifier.verify(file, rejectNonVideoPayload: true)).reason,
        'empty',
      );
      await file.writeAsString('#EXTM3U\nremote.ts\n');
      expect(
        (await verifier.verify(
          file,
          expectedBytes: 1,
          rejectNonVideoPayload: true,
        )).reason,
        'size-mismatch',
      );
    },
  );

  test('new-transfer opt-in accepts tiny and arbitrary binary files', () async {
    final file = File('${temp.path}/video.html');
    for (final bytes in <List<int>>[
      [1, 2, 3, 4],
      [0xff],
      [0, 0, 0, 24, ...ascii.encode('ftypisom')],
      [0x1a, 0x45, 0xdf, 0xa3],
    ]) {
      await file.writeAsBytes(bytes);
      final result = await verifier.verify(
        file,
        expectedBytes: bytes.length,
        rejectNonVideoPayload: true,
      );
      expect(result.isValid, isTrue);
      expect(result.bytes, bytes.length);
    }
  });
}
