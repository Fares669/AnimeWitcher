import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const amount = 131101;
  const chunkEnd = 17 + amount - 1;
  const resource = amount * 3;
  for (final mismatch in [null, 0, 7, 8, 65535, 65536, amount - 1]) {
    test('range verification agrees exactly at byte $mismatch', () async {
      final temp = await Directory.systemTemp.createTemp(
        'scratch-range-lanes-',
      );
      final file = File('${temp.path}/saved.part');
      final initial = Uint8List.fromList(
        List.generate(amount, (i) => (i * 31 + i ~/ 127) & 255),
      );
      await file.writeAsBytes(initial);
      final body = Uint8List.fromList(initial);
      if (mismatch != null) body[mismatch] ^= 1;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seenRanges = <String?>[];
      server.listen((request) async {
        seenRanges.add(request.headers.value(HttpHeaders.rangeHeader));
        request.response.statusCode = HttpStatus.partialContent;
        request.response.contentLength = body.length;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 17-$chunkEnd/$resource',
        );
        request.response.headers.set(HttpHeaders.etagHeader, '"fixture"');
        try {
          for (var i = 0; i < body.length;) {
            final end = i + 9721 > body.length ? body.length : i + 9721;
            request.response.add(Uint8List.sublistView(body, i, end));
            i = end;
          }
          await request.response.close();
        } on HttpException {
          // The app closes the HTTP client immediately on a mismatch.
        } on SocketException {}
      });
      try {
        final task = DownloadTask(
          taskId: 'fixture',
          filename: 'saved.part',
          url: 'http://127.0.0.1:${server.port}/fixture',
          headers: {HttpHeaders.rangeHeader: 'bytes=17-$chunkEnd'},
        );
        final result = await verifySavedRangeSourceV2(
          task,
          file,
          amount,
          resource,
        );
        expect(seenRanges, ['bytes=17-$chunkEnd']);
        expect(
          result,
          mismatch == null
              ? (matches: true, validator: '"fixture"')
              : (matches: false, validator: null),
        );
        expect(await file.readAsBytes(), initial);
      } finally {
        await server.close(force: true);
        await temp.delete(recursive: true);
      }
    });
  }
}
