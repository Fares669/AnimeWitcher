import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_continued_processing_service.dart';
import 'package:animewitcher/core/services/download_range_transfer.dart';
import 'package:animewitcher/core/services/download_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('service teardown barrier does not release a newer init early', () async {
    final barrier = DownloadServiceTeardownBarrier();
    final release = Completer<void>();
    final teardown = barrier.run(() => release.future);

    var settled = false;
    final waiter = barrier.wait().then((_) => settled = true);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);

    release.complete();
    await teardown;
    await waiter;
    expect(settled, isTrue);
  });

  test('global handler lease prevents an old instance unregistering the new one', () {
    final oldLease = DownloadGlobalHandlerLease.acquire();
    final newLease = DownloadGlobalHandlerLease.acquire();

    expect(oldLease.releaseIfCurrent(), isFalse);
    expect(newLease.releaseIfCurrent(), isTrue);
  });

  test('Range dispose joins an active writer before returning', () async {
    final directory = await Directory.systemTemp.createTemp('aw-dispose-range-');
    final file = File('${directory.path}/video.part');
    await file.writeAsBytes([0, 1, 2]);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestSeen = Completer<void>();
    server.listen((request) async {
      final range = request.headers.value('range') ?? '';
      final response = request.response;
      if (range == 'bytes=0-2') {
        response.statusCode = 206;
        response.headers.set('content-range', 'bytes 0-2/10');
        response.headers.set('etag', '"v1"');
        response.add([0, 1, 2]);
        await response.close();
        return;
      }
      response.statusCode = 206;
      response.headers.set('content-range', 'bytes 3-9/10');
      response.headers.set('etag', '"v1"');
      response.add([3]);
      await response.flush();
      if (!requestSeen.isCompleted) requestSeen.complete();
      // Keep the response alive until the client cancellation closes it.
    });

    final dio = Dio();
    final runner = DownloadRangeTransfer(dio);
    addTearDown(() async {
      dio.close(force: true);
      await server.close(force: true);
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    final started = await runner.start(
      id: 'episode',
      url: 'http://127.0.0.1:${server.port}/video',
      headers: const {},
      file: file,
      existingBytes: 3,
      expectedBytes: 10,
      onState: (_, _, _) async {},
      onPaused: (_, _) async {},
    );
    expect(started, isTrue);
    await requestSeen.future.timeout(const Duration(seconds: 5));
    expect(runner.activeTaskIds, contains('episode'));

    await runner.dispose();

    expect(runner.activeTaskIds, isEmpty);
  });
}
