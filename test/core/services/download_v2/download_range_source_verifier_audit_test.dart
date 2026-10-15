import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final cases = <String, bool>{
    'exact206': true,
    'formatted206': true,
    'prefix206': true,
    'whole200': true,
    'wrongStart': false,
    'wrongEnd': false,
    'wrongTotal': false,
    'changedETag': false,
    'wrongBody': false,
    'encoded': false,
    'rangeIgnored': false,
    'truncated': false,
    'oversized': false,
    'weakETag': false,
    'lastModified': true,
  };
  for (final entry in cases.entries) {
    test('streaming range source ${entry.key} preserves local bytes', () async {
      final root = await Directory.systemTemp.createTemp('aw-range-source-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final name = entry.key;
      final whole = name == 'whole200';
      final from = whole ? 0 : 2;
      final requestedBytes = whole
          ? 8
          : name == 'prefix206'
          ? 2
          : 4;
      final to = from + requestedBytes - 1;
      final original = List<int>.generate(
        requestedBytes,
        (index) => from + index,
      );
      final local = File(p.join(root.path, 'range.chunk'));
      await local.writeAsBytes(original);
      final requestObserved = Completer<void>();
      final subscription = server.listen((request) async {
        try {
          expect(
            request.headers.value(HttpHeaders.rangeHeader),
            'bytes=$from-$to',
          );
          expect(
            request.headers.value(HttpHeaders.acceptEncodingHeader),
            'identity',
          );
          expect(
            request.headers.value('Authorization'),
            'Bearer current-source',
          );
          request.response.statusCode = whole || name == 'rangeIgnored'
              ? HttpStatus.ok
              : HttpStatus.partialContent;
          if (request.response.statusCode == HttpStatus.partialContent) {
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              name == 'formatted206'
                  ? 'Bytes $from - $to / 8'
                  : 'bytes ${name == 'wrongStart' ? from + 1 : from}-${name == 'wrongEnd' ? to + 1 : to}/${name == 'wrongTotal' ? 9 : 8}',
            );
          }
          if (name == 'lastModified') {
            request.response.headers.set(
              HttpHeaders.lastModifiedHeader,
              'Wed, 21 Oct 2015 07:28:00 GMT',
            );
          } else {
            request.response.headers.set(
              HttpHeaders.etagHeader,
              name == 'changedETag'
                  ? '"different"'
                  : name == 'weakETag'
                  ? 'W/"resource"'
                  : '"resource"',
            );
          }
          if (name == 'encoded')
            request.response.headers.set(
              HttpHeaders.contentEncodingHeader,
              'gzip',
            );
          final body = [...original];
          if (name == 'wrongBody') body[body.length - 1] = 99;
          if (name == 'truncated') body.removeLast();
          if (name == 'oversized') body.add(99);
          // Chunked responses exercise streamed byte-count validation as well.
          if (body.length == original.length)
            request.response.contentLength = body.length;
          request.response.add(body);
          await request.response.close();
          requestObserved.complete();
        } catch (error, stack) {
          requestObserved.completeError(error, stack);
        }
      });
      try {
        final task = DownloadTask(
          taskId: 'exact-resource-part',
          url: 'http://${server.address.address}:${server.port}/resource',
          filename: 'range.chunk',
          headers: {
            'Range': 'bytes=$from-${whole ? 7 : 5}',
            'Accept-Encoding': 'gzip',
            'Authorization': 'Bearer current-source',
            'If-Range': name == 'lastModified'
                ? 'Wed, 21 Oct 2015 07:28:00 GMT'
                : '"resource"',
          },
        );
        final result = await verifySavedRangeSourceV2(
          task,
          local,
          requestedBytes,
          8,
        );
        await requestObserved.future.timeout(const Duration(seconds: 5));
        expect(result.matches, entry.value);
        if (entry.value) {
          expect(
            result.validator,
            name == 'lastModified'
                ? 'Wed, 21 Oct 2015 07:28:00 GMT'
                : '"resource"',
          );
        }
        expect(await local.readAsBytes(), original);
      } finally {
        await subscription.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    });
  }
  test('cancelling verification closes a held HTTP response', () async {
    final root = await Directory.systemTemp.createTemp('aw-range-cancel-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final local = File(p.join(root.path, 'range.chunk'));
    final original = [2, 3, 4, 5];
    await local.writeAsBytes(original);
    final requestReceived = Completer<HttpRequest>();
    final cancellation = Completer<void>();
    final disconnected = Completer<void>();
    void markDisconnected() {
      if (!disconnected.isCompleted) disconnected.complete();
    }

    final subscription = server.listen(requestReceived.complete);
    Socket? socket;
    StreamSubscription<List<int>>? socketSubscription;
    try {
      final task = DownloadTask(
        taskId: 'cancelled-resource-part',
        url: 'http://${server.address.address}:${server.port}/resource',
        filename: 'range.chunk',
        headers: {'Range': 'bytes=2-5', 'If-Range': '"resource"'},
      );
      final verification = verifySavedRangeSourceV2(
        task,
        local,
        4,
        8,
        cancelled: cancellation.future,
      );
      final request = await requestReceived.future.timeout(
        const Duration(seconds: 2),
      );
      request.response.statusCode = HttpStatus.partialContent;
      request.response.contentLength = original.length;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes 2-5/8',
      );
      request.response.headers.set(HttpHeaders.etagHeader, '"resource"');
      // Keep the body incomplete and observe the real peer disconnect.
      socket = await request.response.detachSocket();
      socketSubscription = socket.listen(
        (_) {},
        onDone: markDisconnected,
        onError: (Object _) => markDisconnected(),
      );
      socket.add(original.take(1).toList());
      await socket.flush();

      cancellation.complete();
      final result = await verification.timeout(const Duration(seconds: 2));
      await disconnected.future.timeout(const Duration(seconds: 2));
      expect(result, (matches: false, validator: null));
      expect(await local.readAsBytes(), original);
    } finally {
      socket?.destroy();
      await socketSubscription?.cancel();
      await subscription.cancel();
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });
  test(
    'unavailable source parks saved bytes without authorizing reuse',
    () async {
      final root = await Directory.systemTemp.createTemp('aw-range-offline-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close(force: true);
      final local = File(p.join(root.path, 'range.chunk'));
      await local.writeAsBytes([2, 3, 4, 5]);
      try {
        final task = DownloadTask(
          taskId: 'offline-resource-part',
          url: 'http://127.0.0.1:$port/closed',
          filename: 'range.chunk',
          headers: {'Range': 'bytes=2-5'},
        );
        final result = await verifySavedRangeSourceV2(task, local, 4, 8);
        expect(result.matches, isFalse);
        expect(await local.readAsBytes(), [2, 3, 4, 5]);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
