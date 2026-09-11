import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_range_transfer.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _totalBytes = 2 * 1024 * 1024;
const _chunkBytes = 64 * 1024;

Future<void> _waitForFileLength(File file, int expected) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if (await file.length() >= expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(
    await file.length(),
    expected,
    reason: 'network ingestion was blocked by a slow persistence callback',
  );
}

Future<HttpServer> _serveRange() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final match = RegExp(r'^bytes=(\d+)-$')
        .firstMatch(request.headers.value('range') ?? '');
    final start = int.tryParse(match?[1] ?? '') ?? 0;
    final response = request.response;
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-${_totalBytes - 1}/$_totalBytes',
    );
    var offset = start;
    while (offset < _totalBytes) {
      final count = (_totalBytes - offset).clamp(0, _chunkBytes);
      response.add(List<int>.filled(count, offset ~/ _chunkBytes & 0xff));
      await response.flush();
      offset += count;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await response.close();
  });
  return server;
}

void main() {
  test(
    'slow progress checkpoint does not backpressure Range ingestion',
    () async {
      final directory = await Directory.systemTemp.createTemp('range-dm25-');
      final file = File('${directory.path}/video.part');
      await file.writeAsBytes(const <int>[]);
      final server = await _serveRange();
      final dio = Dio();
      final runner = DownloadRangeTransfer(dio);
      final entered = Completer<void>();
      final release = Completer<void>();
      final finished = Completer<bool>();
      var nonTerminalCalls = 0;

      try {
        final started = await runner.start(
          id: 'episode',
          url: 'http://127.0.0.1:${server.port}/video',
          headers: const <String, String>{},
          file: file,
          existingBytes: 0,
          expectedBytes: _totalBytes,
          onState: (written, total, complete) async {
            if (complete) {
              if (!finished.isCompleted) finished.complete(true);
              return;
            }
            nonTerminalCalls++;
            if (!entered.isCompleted) {
              entered.complete();
              await release.future;
            }
          },
          onPaused: (_, _) async {
            if (!finished.isCompleted) finished.complete(false);
          },
        );
        expect(started, isTrue);
        await entered.future.timeout(const Duration(seconds: 5));

        // The first persistence callback is deliberately blocked. The network
        // receive loop must still drain into the already-flushed file, while no
        // second persistence write is allowed to run concurrently.
        await _waitForFileLength(file, _totalBytes);
        expect(
          nonTerminalCalls,
          1,
          reason: 'only one persistence write may be in flight',
        );
      } finally {
        if (!release.isCompleted) release.complete();
      }

      expect(await finished.future.timeout(const Duration(seconds: 5)), isTrue);
      expect(
        nonTerminalCalls,
        lessThanOrEqualTo(3),
        reason: 'blocked intermediate checkpoints must collapse to the newest pending snapshot',
      );

      await runner.stop('episode');
      runner.dispose();
      dio.close(force: true);
      await server.close(force: true);
      await directory.delete(recursive: true);
    },
  );

  test(
    'stop joins an in-flight progress checkpoint before paused boundary',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'range-dm25-stop-',
      );
      final file = File('${directory.path}/video.part');
      await file.writeAsBytes(const <int>[]);
      final server = await _serveRange();
      final dio = Dio();
      final runner = DownloadRangeTransfer(dio);
      final entered = Completer<void>();
      final release = Completer<void>();
      final paused = Completer<void>();

      try {
        expect(
          await runner.start(
            id: 'episode',
            url: 'http://127.0.0.1:${server.port}/video',
            headers: const <String, String>{},
            file: file,
            existingBytes: 0,
            expectedBytes: _totalBytes,
            onState: (_, _, complete) async {
              if (!complete && !entered.isCompleted) {
                entered.complete();
                await release.future;
              }
            },
            onPaused: (_, _) async {
              if (!paused.isCompleted) paused.complete();
            },
          ),
          isTrue,
        );
        await entered.future.timeout(const Duration(seconds: 5));
        final stopping = runner.stop('episode');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          paused.isCompleted,
          isFalse,
          reason: 'pause boundary must wait for prior durable checkpoint',
        );
        expect(runner.isActive('episode'), isTrue);
        release.complete();
        await stopping.timeout(const Duration(seconds: 5));
        expect(paused.isCompleted, isTrue);
        expect(runner.isActive('episode'), isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        await runner.stop('episode');
        runner.dispose();
        dio.close(force: true);
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
}
