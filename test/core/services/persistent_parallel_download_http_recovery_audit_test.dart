import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/parallel_download_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This file uses a loopback origin rather than Flutter's all-400 HTTP stub.
  HttpOverrides.global = null;

  for (final status in [401, 403, 404, 400, 410, 416, 503]) {
    test(
      'saved orphan range HTTP $status preserves bytes and classifies renewal',
      () async {
        final harness = await _HttpRecoveryHarness.create();
        final renew = [401, 403, 404].contains(status);
        harness.serve = (request) async {
          request.response.statusCode = status;
          if (status == 416) {
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */20',
            );
          }
          await request.response.close();
        };
        try {
          await harness.restoreSavedRanges();
          await harness.waitForPaused();
          expect(harness.requests, isNotEmpty);
          expect(harness.starts, isEmpty);
          expect(
            harness.renewals,
            renew ? 1 : 0,
            reason: 'Expiry renews once; 416, other client errors and outages do not authorize replacement.',
          );
          await harness.expectSavedBytes();
          expect(await File(await harness.parent.filePath()).exists(), isFalse);
          if (status == 503) {
            expect(
              harness.requests,
              hasLength(6),
              reason: 'Each of the two saved ranges has three bounded probes.',
            );
          }
        } finally {
          await harness.close();
        }
      },
    );
  }

  for (final status in [200, 206]) {
    test(
      'valid HTTP $status saved bytes complete without native restart',
      () async {
        final harness = await _HttpRecoveryHarness.create(
          chunks: status == 200 ? 1 : 2,
        );
        harness.serve = (request) async {
          final range = RegExp(r'^bytes=(\d+)-(\d+)$')
              .firstMatch(request.headers.value(HttpHeaders.rangeHeader)!);
          final from = int.parse(range![1]!);
          final to = int.parse(range[2]!);
          request.response.statusCode = status;
          if (status == 206) {
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $from-$to/${harness.size}',
            );
          }
          request.response.headers.set(
            HttpHeaders.etagHeader,
            '"same-resource"',
          );
          request.response.contentLength = to - from + 1;
          request.response.add(harness.bytes.sublist(from, to + 1));
          await request.response.close();
        };
        try {
          await harness.restoreSavedRanges();
          await _until(() => harness.statuses.contains(TaskStatus.complete));
          await harness.coordinator.flushPendingUpdates();
          expect(harness.starts, isEmpty);
          expect(harness.renewals, 0);
          expect(
            await File(await harness.parent.filePath()).readAsBytes(),
            harness.bytes,
          );
        } finally {
          await harness.close();
        }
      },
    );
  }

  test(
    'ignored partial Range HTTP 200 never adopts or renews unverified bytes',
    () async {
      final harness = await _HttpRecoveryHarness.create();
      harness.serve = (request) async {
        request.response.statusCode = 200;
        request.response.contentLength = harness.size;
        request.response.add(harness.bytes);
        await request.response.close();
      };
      try {
        await harness.restoreSavedRanges();
        await harness.waitForPaused();
        expect(harness.requests, hasLength(6));
        expect(harness.starts, isEmpty);
        expect(harness.renewals, 0);
        await harness.expectSavedBytes();
        expect(await File(await harness.parent.filePath()).exists(), isFalse);
      } finally {
        await harness.close();
      }
    },
  );

  test('simultaneous expired probes request renewal exactly once', () async {
    final harness = await _HttpRecoveryHarness.create();
    final bothReceived = Completer<void>();
    harness.serve = (request) async {
      if (harness.requests.length == 2 && !bothReceived.isCompleted) {
        bothReceived.complete();
      }
      await bothReceived.future;
      request.response.statusCode = 403;
      await request.response.close();
    };
    try {
      await harness.restoreSavedRanges();
      await harness.waitForPaused();
      expect(harness.requests, hasLength(2));
      expect(harness.renewals, 1);
      expect(harness.starts, isEmpty);
      await harness.expectSavedBytes();
    } finally {
      if (!bothReceived.isCompleted) bothReceived.complete();
      await harness.close();
    }
  });

  test(
    'expired probe waits for native sibling ownership before renewal',
    () async {
      final harness = await _HttpRecoveryHarness.create(chunks: 3);
      harness.keepNativeOwners = true;
      harness.serve = (request) async {
        request.response.statusCode = 403;
        await request.response.close();
      };
      try {
        await harness.restoreSavedRanges(leaveLastMissing: true);
        await _until(() => harness.pauseCalls > 0);
        await harness.coordinator.flushPendingUpdates();
        expect(harness.renewals, 0);
        expect(harness.starts, hasLength(1));
        expect(harness.coordinator.isActive(harness.parent.taskId), isTrue);
        final native = harness.starts.single;
        harness.liveIds.clear();
        harness.coordinator.handleUpdate(
          TaskStatusUpdate(native, TaskStatus.paused),
        );
        await _until(() => harness.renewals == 1);
        await harness.coordinator.flushPendingUpdates();
        expect(harness.renewals, 1);
        expect(harness.starts, hasLength(1));
        expect(harness.coordinator.isActive(harness.parent.taskId), isFalse);
        await harness.expectSavedBytes();
      } finally {
        harness.liveIds.clear();
        await harness.close();
      }
    },
  );

  test('user pause fences late HTTP 403 source renewal', () async {
    final harness = await _HttpRecoveryHarness.create();
    final received = Completer<void>();
    final release = Completer<void>();
    harness.serve = (request) async {
      if (!received.isCompleted) received.complete();
      await release.future;
      request.response.statusCode = 403;
      await request.response.close();
    };
    try {
      await harness.restoreSavedRanges();
      await received.future.timeout(const Duration(seconds: 5));
      expect(await harness.coordinator.pause(harness.parent), isTrue);
      release.complete();
      await _until(() => harness.served == harness.requests.length);
      await harness.coordinator.flushPendingUpdates();
      expect(harness.renewals, 0);
      expect(harness.starts, isEmpty);
      expect(harness.coordinator.isActive(harness.parent.taskId), isFalse);
      await harness.expectSavedBytes();
    } finally {
      if (!release.isCompleted) release.complete();
      await harness.close();
    }
  });
}

class _HttpRecoveryHarness {
  _HttpRecoveryHarness(this.root, this.server, {required this.chunks}) {
    parent = ParallelDownloadTask(
      taskId: 'saved-http-recovery',
      url: 'http://${server.address.address}:${server.port}/video',
      filename: 'video.mp4',
      directory: root.path,
      baseDirectory: BaseDirectory.root,
      chunks: chunks,
      allowPause: true,
    );
    coordinator = makeCoordinator();
    subscription = server.listen((request) async {
      requests.add(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      try {
        await serve!(request);
      } finally {
        served++;
      }
    });
  }

  static Future<_HttpRecoveryHarness> create({int chunks = 2}) async =>
      _HttpRecoveryHarness(
        await Directory.systemTemp.createTemp('range-http-recovery-'),
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        chunks: chunks,
      );

  final Directory root;
  final HttpServer server;
  final int chunks;
  int get size => chunks * 10;
  List<int> get bytes => List.generate(size, (index) => index);
  late final ParallelDownloadTask parent;
  late PersistentParallelDownload coordinator;
  late final StreamSubscription<HttpRequest> subscription;
  Future<void> Function(HttpRequest)? serve;
  final requests = <String>[];
  final files = <File>[];
  final statuses = <TaskStatus>[];
  final starts = <DownloadTask>[];
  var renewals = 0;
  var served = 0;
  var pauseCalls = 0;
  var keepNativeOwners = false;
  final liveIds = <String>{};

  PersistentParallelDownload makeCoordinator() => PersistentParallelDownload(
    startPart: (task, _, _) async {
      starts.add(task);
      if (keepNativeOwners) liveIds.add(task.taskId);
      return true;
    },
    pausePart: (task) async {
      pauseCalls++;
      if (!keepNativeOwners) liveIds.remove(task.taskId);
    },
    cancelParts: (_) async {},
    saveRecord: (_) async {},
    recordForId: (_) async => null,
    onUpdate: (update) {
      if (update is TaskStatusUpdate) statuses.add(update.status);
    },
    onPartProgress: (_, _, _) {},
    livePartIds: () async => Set<String>.from(liveIds),
    onSourceRefreshNeeded: (_) => renewals++,
    verifyPartSource: verifySavedRangeSourceV2,
    sourceVerificationRetryDelay: const Duration(milliseconds: 5),
    promoteFile: publishCompletedTestFile,
    diskProgressPollInterval: const Duration(hours: 1),
  );

  Future<void> restoreSavedRanges({bool leaveLastMissing = false}) async {
    await coordinator.start(parent, size);
    await coordinator.dispose();
    final manifest = jsonDecode(
      await File('${await parent.filePath()}.parts/manifest.json')
          .readAsString(),
    ) as Map;
    for (final raw in manifest['parts'] as List) {
      final task = Task.createFromJson(
        Map<String, dynamic>.from(raw['task'] as Map),
      ) as DownloadTask;
      final from = raw['from'] as int;
      final to = raw['to'] as int;
      if (leaveLastMissing && to == size - 1) continue;
      files.add(
        await File(await task.filePath())
            .writeAsBytes(bytes.sublist(from, to + 1)),
      );
    }
    starts.clear();
    liveIds.clear();
    statuses.clear();
    coordinator = makeCoordinator();
    expect(await coordinator.start(parent, size), isTrue);
  }

  Future<void> waitForPaused() async {
    await _until(() => statuses.contains(TaskStatus.paused));
    await coordinator.flushPendingUpdates();
  }

  Future<void> expectSavedBytes() async {
    for (var i = 0; i < files.length; i++) {
      expect(await files[i].readAsBytes(), bytes.sublist(i * 10, (i + 1) * 10));
    }
  }

  Future<void> close() async {
    await coordinator.dispose();
    await subscription.cancel();
    await server.close(force: true);
    await root.delete(recursive: true);
  }
}

Future<void> _until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue, reason: 'Expected recovery to settle');
}
