import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/parallel_download_fixtures.dart';

// These tests use real HTTP streams and files, with a deliberately small
// package-callback adapter. They do not emulate URLSession resumeData or prove
// the iOS background_downloader implementation itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  for (final chunks in [1, 2, 5, 16]) {
    test(
      'loopback $chunks concurrent ranges finish out of order with exact assembly',
      () async {
        final harness = await _TransferHarness.create(
          'outOfOrder206',
          chunks: chunks,
          maxActiveConnections: chunks,
        );
        try {
          await harness.coordinator.start(harness.parent, harness.bytes.length);
          await harness.waitFor(TaskStatus.complete);
          final result = await File(await harness.parent.filePath())
              .readAsBytes();
          expect(sha256.convert(result), sha256.convert(harness.bytes));
          expect(harness.requests, hasLength(chunks));
          expect(harness.peakWorkers, chunks);
          for (var index = 0; index < chunks; index++) {
            expect(harness.requestsFor(index * harness.partSize), 1);
          }
          if (chunks > 1) {
            expect(harness.completedChildIds.first, isNot(endsWith('.part.0')));
          }
          expect(harness.coordinator.activeConnectionCount, 0);
        } finally {
          await harness.close();
        }
      },
    );
  }

  for (final mode in ['exact206', 'interrupted206', 'ignoredRange200']) {
    test(
      'loopback $mode assembles the exact resource without refetching completed ranges',
      () async {
        final harness = await _TransferHarness.create(mode);
        try {
          expect(
            await harness.coordinator.start(
              harness.parent,
              harness.bytes.length,
            ),
            isTrue,
          );
          await harness.waitFor(TaskStatus.complete);
          final finalBytes = await File(await harness.parent.filePath())
              .readAsBytes();
          expect(sha256.convert(finalBytes), sha256.convert(harness.bytes));
          expect(finalBytes, harness.bytes);
          expect(harness.requestsFor(0), 1);
          if (mode == 'interrupted206') {
            expect(harness.requestsFor(harness.partSize), 2);
            expect(
              harness.completedChildIds.where((id) => id.endsWith('.part.0')),
              hasLength(1),
            );
          } else if (mode == 'exact206') {
            expect(harness.requests, hasLength(3));
          } else {
            expect(harness.requests, hasLength(1));
          }
          expect(harness.renewals, 0);
          expect(harness.coordinator.activeConnectionCount, 0);
        } finally {
          await harness.close();
        }
      },
    );
  }

  test('loopback malformed Content-Range preserves completed siblings and rejects the body', () async {
    final harness = await _TransferHarness.create('malformed206');
    try {
      await harness.coordinator.start(harness.parent, harness.bytes.length);
      await harness.waitFor(TaskStatus.paused);
      expect(harness.requestsFor(0), 1);
      expect(harness.requestsFor(harness.partSize), 1);
      expect(harness.requests, hasLength(2));
      expect(await File(await harness.parent.filePath()).exists(), isFalse);
      await harness.expectFirstPartPreserved();
      expect(
        await File('${await harness.parent.filePath()}.parts/1.part').exists(),
        isFalse,
      );
      expect(harness.renewals, 0);
    } finally {
      await harness.close();
    }
  });

  test('loopback HTTP 416 parks safely and explicit resume retains completed siblings', () async {
    final harness = await _TransferHarness.create('range416');
    try {
      await harness.coordinator.start(harness.parent, harness.bytes.length);
      await harness.waitFor(TaskStatus.paused);
      await harness.expectFirstPartPreserved();
      expect(harness.requests, hasLength(2));
      expect(harness.renewals, 0);
      expect(await File(await harness.parent.filePath()).exists(), isFalse);
      harness.mode = 'exact206';
      expect(
        await harness.coordinator.start(harness.parent, harness.bytes.length),
        isTrue,
      );
      await harness.waitFor(TaskStatus.complete);
      final finalBytes = await File(await harness.parent.filePath())
          .readAsBytes();
      expect(sha256.convert(finalBytes), sha256.convert(harness.bytes));
      expect(harness.requestsFor(0), 1);
      expect(harness.requestsFor(harness.partSize), 2);
      expect(harness.requestsFor(harness.partSize * 2), 1);
      expect(harness.renewals, 0);
    } finally {
      await harness.close();
    }
  });
}

class _TransferHarness {
  _TransferHarness(
    this.root,
    this.server,
    this.mode, {
    required this.chunks,
    required int maxActiveConnections,
  }) {
    parent = ParallelDownloadTask(
      taskId: 'loopback-transfer',
      url: 'http://${server.address.address}:${server.port}/video',
      filename: 'video.mp4',
      directory: root.path,
      baseDirectory: BaseDirectory.root,
      chunks: chunks,
      allowPause: true,
    );
    coordinator = PersistentParallelDownload(
      startPart: (task, _, _) async {
        final worker = _HttpWorker();
        workers[task.taskId] = worker;
        if (workers.length > peakWorkers) peakWorkers = workers.length;
        worker.done = Future<void>(() => download(task, worker));
        return true;
      },
      pausePart: (task) => stop(task.taskId),
      cancelParts: (ids) async {
        await Future.wait(ids.map(stop));
      },
      livePartIds: () async => workers.keys.toSet(),
      saveRecord: (record) async {
        records[record.taskId] = record;
        if (record.taskId.contains('.part.') &&
            record.status == TaskStatus.complete) {
          completedChildIds.add(record.taskId);
        }
      },
      recordForId: (id) async => records[id],
      onUpdate: (update) {
        if (update is TaskStatusUpdate) statuses.add(update.status);
      },
      onPartProgress: (_, _, _) {},
      onSourceRefreshNeeded: (_) => renewals++,
      verifyPartSource: verifySavedRangeSourceV2,
      promoteFile: publishCompletedTestFile,
      maxActiveConnections: maxActiveConnections,
      recoveryDelay: const Duration(milliseconds: 5),
      sourceVerificationRetryDelay: const Duration(milliseconds: 5),
      diskProgressPollInterval: const Duration(hours: 1),
      tailStallDelay: const Duration(hours: 1),
      pendingStartLeaseDelay: const Duration(hours: 1),
    );
    subscription = server.listen(serve);
  }

  static Future<_TransferHarness> create(
    String mode, {
    int chunks = 3,
    int maxActiveConnections = 1,
  }) async => _TransferHarness(
    await Directory.systemTemp.createTemp('loopback-transfer-'),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    mode,
    chunks: chunks,
    maxActiveConnections: maxActiveConnections,
  );

  final Directory root;
  final HttpServer server;
  String mode;
  final int chunks;
  final allRequests = Completer<void>();
  int peakWorkers = 0;
  final int partSize = 8192;
  late final bytes = List<int>.generate(
    partSize * chunks,
    (index) => (index * 37 + index ~/ 251) & 255,
  );
  late final ParallelDownloadTask parent;
  late final PersistentParallelDownload coordinator;
  late final StreamSubscription<HttpRequest> subscription;
  final workers = <String, _HttpWorker>{};
  final records = <String, TaskRecord>{};
  final requests = <(int, int)>[];
  final statuses = <TaskStatus>[];
  final completedChildIds = <String>[];
  var renewals = 0;

  int requestsFor(int from) =>
      requests.where((range) => range.$1 == from).length;

  Future<void> serve(HttpRequest request) async {
    final match = RegExp(r'^bytes=(\d+)-(\d+)$')
        .firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (match == null) {
      request.response.statusCode = 400;
      await request.response.close();
      return;
    }
    final from = int.parse(match[1]!);
    final to = int.parse(match[2]!);
    requests.add((from, to));
    expect(request.headers.value(HttpHeaders.acceptEncodingHeader), 'identity');
    final response = request.response;
    if (mode == 'range416' && from == partSize) {
      response.statusCode = 416;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${bytes.length}',
      );
      await response.close();
      return;
    }
    if (mode == 'ignoredRange200') {
      response.statusCode = 200;
      response.contentLength = bytes.length;
      response.add(bytes);
      await response.close();
      return;
    }
    response.statusCode = 206;
    final responseTotal = mode == 'malformed206' && from == partSize
        ? bytes.length + 1
        : bytes.length;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $from-$to/$responseTotal',
    );
    response.headers.set(HttpHeaders.etagHeader, '"loopback-resource"');
    response.contentLength = to - from + 1;
    if (mode == 'interrupted206' &&
        from == partSize &&
        requestsFor(from) == 1) {
      final socket = await response.detachSocket();
      socket.add(bytes.sublist(from, from + 1024));
      await socket.flush();
      socket.destroy();
      return;
    }
    if (mode == 'outOfOrder206') {
      if (requests.length == chunks && !allRequests.isCompleted) {
        allRequests.complete();
      }
      await allRequests.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(
        Duration(milliseconds: (chunks - from ~/ partSize) * 5),
      );
    }
    response.add(bytes.sublist(from, to + 1));
    await response.close();
  }

  Future<void> download(DownloadTask task, _HttpWorker worker) async {
    RandomAccessFile? output;
    TaskStatusUpdate? terminal;
    try {
      coordinator.handleUpdate(TaskStatusUpdate(task, TaskStatus.running));
      final request = await worker.client.getUrl(Uri.parse(task.url));
      task.headers.forEach(request.headers.set);
      final response = await request.close();
      final headers = <String, String>{};
      response.headers.forEach(
        (name, values) => headers[name] = values.join(', '),
      );
      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.drain<void>();
        terminal = TaskStatusUpdate(task, TaskStatus.failed).copyWith(
          responseStatusCode: response.statusCode,
          responseHeaders: headers,
        );
      } else {
        final file = File(await task.filePath());
        await file.parent.create(recursive: true);
        output = await file.open(mode: FileMode.write);
        await for (final chunk in response) {
          await output.writeFrom(chunk);
        }
        await output.flush();
        terminal = TaskStatusUpdate(task, TaskStatus.complete).copyWith(
          responseStatusCode: response.statusCode,
          responseHeaders: headers,
        );
      }
    } on SocketException catch (_) {
      terminal = TaskStatusUpdate(
        task,
        worker.stopped ? TaskStatus.paused : TaskStatus.failed,
      );
    } on HttpException catch (_) {
      terminal = TaskStatusUpdate(
        task,
        worker.stopped ? TaskStatus.paused : TaskStatus.failed,
      );
    } finally {
      await output?.close();
      worker.client.close(force: true);
      if (identical(workers[task.taskId], worker)) workers.remove(task.taskId);
      if (terminal != null) coordinator.handleUpdate(terminal);
    }
  }

  Future<void> stop(String id) async {
    final worker = workers[id];
    if (worker == null) return;
    worker.stopped = true;
    worker.client.close(force: true);
    await worker.done.timeout(const Duration(seconds: 3));
  }

  Future<void> expectFirstPartPreserved() async {
    final first = File('${await parent.filePath()}.parts/0.part');
    expect(
      sha256.convert(await first.readAsBytes()),
      sha256.convert(bytes.sublist(0, partSize)),
    );
  }

  Future<void> waitFor(TaskStatus status) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (!statuses.contains(status) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(statuses, contains(status));
    await coordinator.flushPendingUpdates();
  }

  Future<void> close() async {
    await coordinator.dispose();
    await Future.wait(workers.keys.toList().map(stop));
    await subscription.cancel();
    await server.close(force: true);
    await root.delete(recursive: true);
  }
}

class _HttpWorker {
  final HttpClient client = HttpClient()..autoUncompress = false;
  late Future<void> done;
  bool stopped = false;
}
