import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory pathRoot;
  late PathProviderPlatform previousPaths;
  setUp(() async {
    pathRoot = await Directory.systemTemp.createTemp('aw-gateway-platform-paths-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _PrivatePaths(
      p.join(pathRoot.path, 'support'), p.join(pathRoot.path, 'documents'), pathRoot.path,
    );
  });
  tearDown(() async {
    PathProviderPlatform.instance = previousPaths;
    await pathRoot.delete(recursive: true);
  });

  for (final unknown in [false, true]) {
    test('gateway ${unknown ? 'unknown native settlement' : 'negative cancel ACK'} preserves owned range bytes and checkpoint', () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.downloader.cancelAccepted = unknown;
      f.downloader.unknownLiveness = unknown;
      await expectLater(f.handle.cancel(), throwsA(unknown ? isA<TimeoutException>() : isA<StateError>()));
      expect(f.handle.current.status, isNot(DownloadTransportStatus.canceled));
      expect(await f.manifest.exists(), isTrue);
      expect(await f.part.readAsBytes(), [1, 2]);
      if (!unknown) expect(f.downloader.native.map((task) => task.taskId), contains(f.child.taskId));
    });
  }

  test('missing native cancel ACK releases the coordinator without deleting owned bytes', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final lostAck = Completer<bool>();
    f.downloader.cancelAck = lostAck.future;
    Object? failure;
    var finished = false;
    final cancellation = f.handle.cancel().then<void>((_) {
      finished = true;
    }, onError: (Object error, StackTrace _) {
      failure = error;
      finished = true;
    });
    await f.downloader.cancelEntered.future;
    await Future<void>.delayed(const Duration(milliseconds: 5200));
    final bounded = finished;
    if (!lostAck.isCompleted) lostAck.complete(false);
    await cancellation;
    f.downloader.cancelAck = null;
    expect(bounded, isTrue, reason: 'a lost command ACK must not occupy the per-parent FIFO indefinitely');
    expect(failure, isA<TimeoutException>());
    expect(f.handle.current.status, isNot(DownloadTransportStatus.canceled));
    expect(await f.manifest.exists(), isTrue);
    expect(await f.part.readAsBytes(), [1, 2]);
    expect(await f.handle.cancel(), isTrue, reason: 'delete/cancel remains retryable after an uncertain ACK');
    expect(await f.manifest.exists(), isFalse);
  });

  for (final committed in [false, true]) {
    for (final accepted in [false, true]) {
    test('uncertain native enqueue ${committed ? 'with' : 'without'} commit proof and late ACK=$accepted retains writer ownership', () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      final enqueueAck = Completer<bool>();
      addTearDown(() { if (!enqueueAck.isCompleted) enqueueAck.complete(accepted); });
      f.downloader.enqueueAck = enqueueAck.future;
      f.downloader.commitBeforeEnqueueAck = committed;
      var resumed = false;
      final resume = f.handle.resume().then((_) { resumed = true; });
      await f.downloader.enqueueEntered.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 5200));
      final bounded = resumed;
      if (!bounded) enqueueAck.complete(accepted);
      await resume;
      expect(bounded, isTrue, reason: 'a lost enqueue ACK cannot hold the per-parent control queue');
      if (committed) {
        expect(await f.handle.cancel(), isTrue,
          reason: 'exact raw native ownership proves the already-submitted enqueue committed');
        expect(await f.manifest.exists(), isFalse);
      } else {
        await expectLater(f.handle.cancel(), throwsA(isA<TimeoutException>()));
        expect(await f.manifest.exists(), isTrue);
        expect(await f.part.readAsBytes(), [1, 2]);
      }
      if (!enqueueAck.isCompleted) enqueueAck.complete(accepted);
      await Future<void>.delayed(Duration.zero);
      f.downloader.enqueueAck = null;
      expect(await f.handle.cancel(), isTrue);
      expect(f.downloader.native, isEmpty);
    });
    }
  }

  test('iOS gateway pause stops all writers and retains package resume checkpoints', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.downloader.keepResumeData = true;
    expect(await f.handle.pause(), isTrue);
    expect(f.downloader.pauseCalls, 1);
    expect(f.downloader.native, isEmpty);
    expect(f.handle.current.status, DownloadTransportStatus.paused);
    expect(f.handle.current.activeConnections, 0);
    expect(await f.part.readAsBytes(), [1, 2]);
    expect(f.downloader.testStorage.resumeData.keys, contains(f.child.taskId));
    final beforeResume = f.downloader.enqueueCalls;
    expect(await f.handle.resume(), isTrue);
    expect(f.downloader.resumedIds, contains(f.child.taskId),
      reason: 'the package remains the authority that consumes native resumeData');
    expect(f.downloader.enqueueCalls, greaterThan(beforeResume));
    expect(await f.part.readAsBytes(), [1, 2]);
  });

  test('resume status reconciles durable bytes and progress on the same basis', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    await f.part.writeAsBytes([1, 2, 3, 4]);
    f.downloader.native.clear();
    f.downloader.updatesController.add(TaskStatusUpdate(f.child, TaskStatus.complete, null, null, {
      'content-range': 'bytes 0-3/8',
      'etag': '"resource"',
    }, 206));
    var complete = false;
    for (var index = 0; index < 200; index++) {
      final state = jsonDecode(await f.manifest.readAsString()) as Map;
      complete = ((state['parts'] as List).first as Map)['complete'] == true;
      if (complete) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(complete, isTrue);
    final snapshots = <DownloadTransportSnapshot>[];
    final subscription = f.handle.snapshots.listen(snapshots.add);
    try {
      expect(await f.handle.resume(), isTrue);
      final refreshed = snapshots.firstWhere((snapshot) => snapshot.status == DownloadTransportStatus.queued);
      expect(refreshed.transferredBytes, 4);
      expect(refreshed.progress, .5,
        reason: 'status-only reconciliation cannot keep stale progress beside newer durable bytes');
      expect(await f.part.readAsBytes(), [1, 2, 3, 4]);
      expect(f.downloader.native.any((task) => task.taskId == f.child.taskId), isFalse);
    } finally {
      await subscription.cancel();
    }
  });

  test('pause and immediate resume await the same attempt native checkpoint writes', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final checkpoint = Completer<void>();
    f.downloader.keepResumeData = true;
    f.downloader.pauseCheckpointGate = checkpoint.future;
    final stale = f.child.copyWith(metaData: jsonEncode({
      'parentTaskId': f.handle.taskId, 'attemptGeneration': 0,
    }));
    f.downloader.testStorage.paused.add(stale);
    f.downloader.testStorage.resumeData[f.child.taskId] = ResumeData(stale, 'stale-attempt');
    var pauseFinished = false;
    final pause = f.handle.pause().then((accepted) { pauseFinished = true; return accepted; });
    await f.downloader.pauseEntered.future;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final acknowledgedBeforeCheckpoint = pauseFinished;
    final resume = f.handle.resume();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final startsBeforeCheckpoint = f.downloader.enqueueCalls;
    checkpoint.complete();
    expect(await pause, isTrue);
    expect(await resume, isTrue);
    expect(acknowledgedBeforeCheckpoint, isFalse,
      reason: 'native pause ACK can precede asynchronous package persistence');
    expect(startsBeforeCheckpoint, 0,
      reason: 'late resumeData must not race a fresh writer or range restart');
    expect(f.downloader.resumedIds, contains(f.child.taskId));
  });

  test('resume started before native pause ACK also waits for its delayed checkpoint', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final acknowledgement = Completer<void>();
    final checkpoint = Completer<void>();
    f.downloader.pauseAckGate = acknowledgement.future;
    f.downloader.pauseCheckpointGate = checkpoint.future;
    final pause = f.handle.pause();
    await f.downloader.pauseEntered.future;
    final resume = f.handle.resume();
    acknowledgement.complete();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final startsBeforeCheckpoint = f.downloader.enqueueCalls;
    checkpoint.complete();
    expect(await pause, isTrue);
    expect(await resume, isTrue);
    expect(startsBeforeCheckpoint, 0);
    expect(f.downloader.resumedIds, contains(f.child.taskId));
  });

  test('native pause without resumeData succeeds after settling and preserving durable ranges', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.downloader.pauseAccepted = false;
    f.downloader.stopOnRejectedPause = true;
    expect(await f.handle.pause(), isTrue);
    expect(f.downloader.native, isEmpty);
    expect(f.handle.current.status, DownloadTransportStatus.paused);
    expect(f.handle.current.activeConnections, 0);
    expect(await f.part.readAsBytes(), [1, 2]);
    expect(await f.manifest.exists(), isTrue);
    expect(await f.handle.resume(), isTrue);
    expect(await f.part.readAsBytes(), [1, 2]);
    expect(await File('${f.part.path}.download').readAsBytes(), [1, 2],
      reason: 'range restart must retain the durable partial prefix');
  });

  test('missing iOS checkpoint reconciles lost in-flight bytes before pause returns', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    await f.part.delete(); // URLSession's private temporary bytes did not survive.
    final observed = <DownloadTransportSnapshot>[];
    final subscription = f.handle.snapshots.listen(observed.add);
    addTearDown(subscription.cancel);
    f.downloader.pauseAccepted = false;
    f.downloader.stopOnRejectedPause = true;
    expect(await f.handle.pause(), isTrue);
    expect(f.handle.current.status, DownloadTransportStatus.paused);
    expect(f.handle.current.activeConnections, 0);
    expect(f.handle.current.transferredBytes, 0);
    expect(f.handle.current.progress, 0);
    expect(observed.where((snapshot) => snapshot.status == DownloadTransportStatus.paused),
      everyElement(isA<DownloadTransportSnapshot>().having(
        (snapshot) => snapshot.transferredBytes, 'settled paused bytes', 0)));
    final checkpoint = jsonDecode(await f.manifest.readAsString()) as Map;
    final child = (checkpoint['parts'] as List).first as Map;
    expect(child['credibleProgress'], 0);
    expect(child['durableBytes'], 0);
    // Late callbacks belong to the canceled native execution, not recovery.
    f.downloader.updatesController.add(TaskProgressUpdate(f.child, .9, 4));
    f.downloader.updatesController.add(TaskStatusUpdate(f.child, TaskStatus.failed));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(f.handle.current.progress, 0);
    expect(f.handle.current.status, DownloadTransportStatus.paused);
    expect(f.downloader.enqueueCalls, 0);
    expect(await f.handle.resume(), isTrue);
  });

  for (final prefixSurvives in [false, true]) {
    test('checkpointless pause preserves completed sibling and restart truth, prefix=$prefixSurvives', () async {
      final f = await _Fixture.create(completedSibling: true);
      addTearDown(f.dispose);
      final before = jsonDecode(await f.manifest.readAsString()) as Map;
      final siblingTask = Task.createFromJson(Map<String, dynamic>.from(
        ((before['parts'] as List)[1] as Map)['task'] as Map));
      final sibling = File(await siblingTask.filePath());
      final digest = sha256.convert(await sibling.readAsBytes());
      if (!prefixSurvives) await f.part.delete();
      f.downloader.pauseAccepted = false;
      f.downloader.stopOnRejectedPause = true;
      expect(await f.handle.pause(), isTrue);
      expect(f.handle.current.transferredBytes, prefixSurvives ? 6 : 4);
      expect(f.handle.current.progress, prefixSurvives ? .75 : .5);
      expect(sha256.convert(await sibling.readAsBytes()), digest);
      final persisted = jsonDecode(await f.manifest.readAsString()) as Map;
      final completed = (persisted['parts'] as List)[1] as Map;
      expect(completed['complete'], isTrue);
      expect(completed['durableBytes'], 4);
      // A new gateway/coordinator reconstructs only the surviving bytes.
      final restarted = (await _gateway(f.downloader).attach(f.handle.taskId))!;
      expect(restarted.current.transferredBytes, prefixSurvives ? 6 : 4);
      expect(restarted.current.progress, prefixSurvives ? .75 : .5);
      expect(await restarted.pause(), isTrue);
      expect(sha256.convert(await sibling.readAsBytes()), digest);
    });
  }

  test('repeated checkpointless pause and resume never throws or credits lost bytes', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    await f.part.delete();
    f.downloader.pauseAccepted = false;
    f.downloader.stopOnRejectedPause = true;
    for (var attempt = 0; attempt < 9; attempt++) {
      expect(await f.handle.pause(), isTrue);
      expect(f.handle.current.progress, 0);
      expect(f.handle.current.activeConnections, 0);
      expect(f.downloader.native, isEmpty);
      expect(await f.handle.resume(), isTrue);
    }
    expect(await f.handle.pause(), isTrue);
    expect(f.handle.current.progress, 0);
  });

  for (final scenario in ['same-resource', 'changed-bytes', 'changed-size', 'expired']) {
    test('in-place source renewal retains exact completed ranges: $scenario', () async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() { HttpOverrides.global = previousHttp; });
      final f = await _Fixture.create(completedSibling: true);
      addTearDown(f.dispose);
      f.downloader.pauseAccepted = false;
      f.downloader.stopOnRejectedPause = true;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requestedRanges = <String>[];
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader)!;
        requestedRanges.add(range);
        final bounds = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
        final from = int.parse(bounds[1]!);
        final to = int.parse(bounds[2]!);
        final response = request.response;
        if (scenario == 'expired') {
          response.statusCode = 403;
        } else {
          response.statusCode = 206;
          response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-$to/8');
          response.contentLength = to - from + 1;
          response.add([for (var offset = from; offset <= to; offset++)
            scenario == 'changed-bytes' ? 99 : offset + 1]);
        }
        await response.close();
      });
      final before = jsonDecode(await f.manifest.readAsString()) as Map;
      final siblingTask = Task.createFromJson(Map<String, dynamic>.from(
        ((before['parts'] as List)[1] as Map)['task'] as Map));
      final sibling = File(await siblingTask.filePath());
      final originalHash = sha256.convert(await sibling.readAsBytes());
      final renewal = f.handle as SourceRenewingDownloadTransportHandleV2;
      final url = 'http://${server.address.address}:${server.port}/fresh-video';
      expect(await renewal.replaceSource(url: url, headers: {},
        expectedBytes: scenario == 'changed-size' ? 9 : 8), scenario == 'same-resource');
      expect(f.downloader.cancelCalls, 0);
      expect(f.downloader.enqueueCalls, 0);
      expect(await f.part.readAsBytes(), [1, 2]);
      expect(sha256.convert(await sibling.readAsBytes()), originalHash);
      final after = jsonDecode(await f.manifest.readAsString()) as Map;
      expect((after['parts'] as List).map((part) => part['task']['taskId']),
          (before['parts'] as List).map((part) => part['task']['taskId']));
      expect((after['parts'] as List)[1]['complete'], isTrue);
      final childUrl = (after['parts'] as List).first['task']['url'];
      expect(childUrl, scenario == 'same-resource' ? url : f.child.url);
      if (scenario == 'same-resource') {
        expect(requestedRanges, ['bytes=0-1', 'bytes=4-7']);
        expect(f.handle.current.progress, .75);
      }
      if (scenario == 'changed-size') expect(requestedRanges, isEmpty);
    });
  }

  test('first stopped-pause checkpoint failure preserves the pause repair fence', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    expect(await f.handle.resume(), isTrue);
    await f.part.delete();
    f.downloader.pauseAccepted = false;
    f.downloader.stopOnRejectedPause = true;
    final blocked = await Directory('${f.manifest.path}.tmp').create();
    addTearDown(() async { if (await blocked.exists()) await blocked.delete(); });
    final snapshots = <DownloadTransportSnapshot>[];
    final subscription = f.handle.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);
    await expectLater(f.handle.pause(), throwsA(isA<DownloadPauseCheckpointException>()));
    expect(f.downloader.native, isEmpty);
    expect(snapshots.where((snapshot) => snapshot.status == DownloadTransportStatus.paused), isEmpty);
    await blocked.delete();
    expect(await f.handle.resume(), isTrue);
    final checkpoint = jsonDecode(await f.manifest.readAsString()) as Map;
    expect((checkpoint['parts'] as List).first['credibleProgress'], 0);
  });

  test('failed stopped-pause checkpoint stays fenced until repair is persisted', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    expect(await f.handle.resume(), isTrue);
    await f.part.delete();
    f.downloader.pauseAccepted = false;
    f.downloader.stopOnRejectedPause = true;
    final blocked = Directory('${f.manifest.path}.tmp');
    var injected = false;
    f.downloader.testStorage.onStoreRecord = (record) async {
      if (!injected && record.taskId == f.handle.taskId && record.status == TaskStatus.paused) {
        injected = true;
        await blocked.create();
      }
    };
    addTearDown(() async {
      f.downloader.testStorage.onStoreRecord = null;
      if (await blocked.exists()) await blocked.delete();
    });
    final snapshots = <DownloadTransportSnapshot>[];
    final subscription = f.handle.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);
    await expectLater(f.handle.pause(), throwsA(isA<DownloadPauseCheckpointException>()));
    expect(injected, isTrue);
    expect(f.downloader.native, isEmpty);
    expect(snapshots.where((snapshot) => snapshot.status == DownloadTransportStatus.paused), isEmpty);
    final starts = f.downloader.enqueueCalls;
    await expectLater(f.handle.resume(), throwsA(isA<DownloadPauseCheckpointException>()));
    expect(f.downloader.enqueueCalls, starts, reason: 'failed repair cannot start a new writer');
    await blocked.delete();
    f.downloader.testStorage.onStoreRecord = null;
    expect(await f.handle.resume(), isTrue);
    final checkpoint = jsonDecode(await f.manifest.readAsString()) as Map;
    expect((checkpoint['parts'] as List).first['credibleProgress'], 0);
  });

  for (final control in ['pause', 'cancel', 'interrupt']) {
    test('$control interrupts in-flight source renewal HTTP verification', () async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() { HttpOverrides.global = previousHttp; });
      final f = await _Fixture.create(completedSibling: true);
      addTearDown(f.dispose);
      f.downloader.pauseAccepted = false;
      f.downloader.stopOnRejectedPause = true;
      final entered = Completer<void>();
      final release = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
      });
      server.listen((request) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
        request.response.statusCode = 403;
        try { await request.response.close(); } catch (_) {}
      });
      final renewable = f.handle as SourceRenewingDownloadTransportHandleV2;
      final renewing = renewable.replaceSource(
        url: 'http://${server.address.address}:${server.port}/fresh', headers: {}, expectedBytes: 8);
      await entered.future.timeout(const Duration(seconds: 2));
      final stopping = switch (control) {
        'pause' => f.handle.pause(),
        'cancel' => f.handle.cancel(),
        _ => Future<bool>.sync(() { renewable.interruptSourceRenewal(); return true; }),
      };
      expect(await stopping.timeout(const Duration(seconds: 2)), isTrue);
      expect(await renewing.timeout(const Duration(seconds: 2)), isFalse);
      expect(release.isCompleted, isFalse, reason: 'control did not wait for the stalled server');
      expect(f.downloader.enqueueCalls, 0);
    });
  }

  test('a range completed during native pause keeps its file without needing resumeData', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final gate = Completer<void>();
    f.downloader.pauseAckGate = gate.future;
    f.downloader.keepResumeData = false;
    f.downloader.pauseAccepted = false;
    f.downloader.stopOnRejectedPause = true;
    final pause = f.handle.pause();
    await f.downloader.pauseEntered.future;
    await f.part.writeAsBytes([1, 2, 3, 4], flush: true);
    gate.complete();
    expect(await pause, isTrue);
    expect(f.handle.current.status, DownloadTransportStatus.paused);
    expect(f.handle.current.activeConnections, 0);
    expect(await f.part.readAsBytes(), [1, 2, 3, 4]);
  });

  test('delete can discard an unavailable pause checkpoint after writers stop', () async {
    final f = await _Fixture.create(discard: true);
    addTearDown(f.dispose);
    f.downloader.keepResumeData = false;
    await expectLater(f.handle.pause(), throwsA(isA<TimeoutException>()));
    expect(await f.handle.cancel(), isTrue);
    await f.gateway.removeTracking(f.handle.taskId);
    expect(await f.manifest.exists(), isFalse);
    expect(f.downloader.native, isEmpty);
  });

  test('checkpoint timeout keeps resume and delete fenced until pending writes settle', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final checkpoint = Completer<void>();
    f.downloader.pauseCheckpointGate = checkpoint.future;
    await expectLater(f.handle.pause(), throwsA(isA<TimeoutException>()));
    expect(f.handle.current.status, DownloadTransportStatus.paused);
    expect(f.downloader.native, isEmpty);
    final resume = expectLater(f.handle.resume(), throwsA(isA<TimeoutException>()));
    final cancel = expectLater(f.handle.cancel(), throwsA(isA<TimeoutException>()));
    await Future.wait([resume, cancel]);
    expect(f.downloader.enqueueCalls, 0);
    expect(await f.manifest.exists(), isTrue);
    expect(await f.part.readAsBytes(), [1, 2]);
    checkpoint.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(await f.handle.cancel(), isTrue);
    await f.gateway.removeTracking(f.handle.taskId);
    expect(await f.manifest.exists(), isFalse);
    expect(f.downloader.testStorage.paused, isEmpty);
    expect(f.downloader.testStorage.resumeData, isEmpty);
  });

  test('lost pause ACK retains the original operation even after native writer disappears', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final manifest = jsonDecode(await f.manifest.readAsString()) as Map;
    final second = Task.createFromJson(Map<String, dynamic>.from(
      ((manifest['parts'] as List)[1] as Map)['task'] as Map)) as DownloadTask;
    await File(await second.filePath()).writeAsBytes([5, 6, 7, 8], flush: true);
    f.downloader.updatesController.add(TaskStatusUpdate(second, TaskStatus.complete, null, null, {
      'content-range': 'bytes 4-7/8', 'etag': '"resource"',
    }, 206));
    for (var index = 0; index < 200; index++) {
      final state = jsonDecode(await f.manifest.readAsString()) as Map;
      if (((state['parts'] as List)[1] as Map)['complete'] == true) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final acknowledgement = Completer<void>();
    f.downloader.pauseAckGate = acknowledgement.future;
    f.downloader.stopBeforePauseAck = true;
    await expectLater(f.handle.pause(), throwsA(isA<TimeoutException>()));
    expect(f.downloader.native, isEmpty);
    expect(f.handle.current.status, DownloadTransportStatus.running);
    expect(f.downloader.pauseCalls, 1,
      reason: 'an uncertain native pause must not be sent destructively twice');
    final resume = expectLater(f.handle.resume(), throwsA(isA<TimeoutException>()));
    final cancel = expectLater(f.handle.cancel(), throwsA(isA<TimeoutException>()));
    await Future.wait([resume, cancel]);
    expect(f.downloader.enqueueCalls, 0);
    expect(await f.manifest.exists(), isTrue);
    acknowledgement.complete();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(f.downloader.enqueueCalls, 0,
      reason: 'late pause acknowledgement must not authorize automatic range recovery');
    expect(await f.handle.resume(), isTrue);
    expect(f.downloader.resumedIds, contains(f.child.taskId));
    final resumed = f.downloader.native.singleWhere((task) => task.taskId == f.child.taskId);
    expect((jsonDecode(resumed.metaData) as Map)['attemptGeneration'], greaterThan(1),
      reason: 'a late old paused callback must not match the resumed native execution');
    final starts = f.downloader.enqueueCalls;
    f.downloader.updatesController.add(TaskStatusUpdate(f.child, TaskStatus.paused));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(f.downloader.enqueueCalls, starts);
    final state = jsonDecode(await f.manifest.readAsString()) as Map;
    expect(((state['parts'] as List).first as Map)['attemptGeneration'],
      (jsonDecode(resumed.metaData) as Map)['attemptGeneration']);
    expect(await f.part.readAsBytes(), [1, 2]);
  });

  test('natural completion waits for internal pause checkpoint writes before tracking cleanup', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    const channel = MethodChannel('com.animewitcher.app/download_continued_processing');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'availableDiskBytes') return 1024 * 1024 * 1024;
      if (call.method == 'promoteCompletedFile') {
        final args = Map<String, Object?>.from(call.arguments as Map);
        await File(args['sourcePath']! as String).rename(args['targetPath']! as String);
        return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final checkpoint = Completer<void>();
    addTearDown(() { if (!checkpoint.isCompleted) checkpoint.complete(); });
    f.downloader.pauseCheckpointGate = checkpoint.future;
    expect(await f.handle.resume(), isTrue);
    await f.part.writeAsBytes([1, 2, 3, 4], flush: true);
    final first = f.downloader.native.singleWhere((task) => task.taskId == f.child.taskId);
    f.downloader.updatesController.add(TaskProgressUpdate(first, .999, 4));
    await f.downloader.pauseEntered.future.timeout(const Duration(seconds: 2));
    f.downloader.updatesController.add(TaskStatusUpdate(first, TaskStatus.complete, null, null,
      {'content-range': 'bytes 0-3/8', 'etag': '"resource"'}, 206));
    var firstComplete = false;
    for (var index = 0; index < 200; index++) {
      firstComplete = (await f.downloader.database.recordForId(first.taskId))?.status == TaskStatus.complete;
      if (firstComplete) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(firstComplete, isTrue);
    final second = f.downloader.native.single as DownloadTask;
    await File(await second.filePath()).writeAsBytes([5, 6, 7, 8], flush: true);
    f.downloader.native.clear();
    f.downloader.updatesController.add(TaskStatusUpdate(second, TaskStatus.complete, null, null,
      {'content-range': 'bytes 4-7/8', 'etag': '"resource"'}, 206));
    for (var index = 0; index < 200 && f.handle.current.status != DownloadTransportStatus.complete; index++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(f.handle.current.status, DownloadTransportStatus.complete);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await f.downloader.database.recordForId(first.taskId), isNotNull,
      reason: 'terminal cleanup must retain tracking until checkpoint writes settle');
    checkpoint.complete();
    await f.downloader.pauseStored.future;
    for (var index = 0; index < 200 &&
        (f.downloader.testStorage.paused.isNotEmpty || f.downloader.testStorage.resumeData.isNotEmpty); index++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(f.downloader.testStorage.paused, isEmpty);
    expect(f.downloader.testStorage.resumeData, isEmpty);
    expect(await File('${f.root.path}/video.mp4').readAsBytes(), [1, 2, 3, 4, 5, 6, 7, 8]);
  });

  test('pause never cancels an already stopped native child with a saved checkpoint', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.downloader.native.clear();
    f.downloader.testStorage.paused.add(f.child);
    f.downloader.testStorage.resumeData[f.child.taskId] = ResumeData(f.child, 'existing-checkpoint');
    expect(await f.handle.pause(), isTrue);
    expect(f.downloader.pauseCalls, 0,
      reason: 're-pausing a canceled native worker can invalidate its saved resumeData');
    expect(f.downloader.testStorage.resumeData[f.child.taskId]?.data, 'existing-checkpoint');
  });

  test('rejected native pause never acknowledges paused while writer remains live', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.downloader.pauseAccepted = false;
    expect(await f.handle.pause(), isFalse);
    expect(f.downloader.pauseCalls, 2);
    expect(f.handle.current.status, DownloadTransportStatus.running);
    expect(f.handle.current.activeConnections, 1);
    expect(f.downloader.native.map((task) => task.taskId), contains(f.child.taskId));
    expect(await f.part.readAsBytes(), [1, 2]);
    expect(await f.manifest.exists(), isTrue);
  });

  test('pause during package resume-state read prevents a subsequent native enqueue', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final resumeState = Completer<bool>();
    f.downloader.canResumeAck = resumeState.future;
    final resume = f.handle.resume();
    await f.downloader.resumeStateEntered.future.timeout(const Duration(seconds: 2));
    final pause = f.handle.pause();
    await Future<void>.delayed(Duration.zero);
    resumeState.complete(false);
    await resume;
    await pause;
    expect(f.downloader.enqueueCalls, 0,
      reason: 'native admission must recheck control intent after package IO');
  });

  test('uncertain range resume uses new running occurrence as commit proof', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    final acknowledgement = Completer<bool>();
    addTearDown(() { if (!acknowledgement.isCompleted) acknowledgement.complete(false); });
    f.downloader.canResumeAck = Future<bool>.value(true);
    f.downloader.enqueueAck = acknowledgement.future;
    f.downloader.commitBeforeEnqueueAck = true;
    expect(await f.handle.resume().timeout(const Duration(seconds: 7)), isTrue);
    expect(f.downloader.resumeCalls, 1);
    expect(f.downloader.native, hasLength(2));
    expect(await f.handle.cancel(), isTrue);
    acknowledgement.complete(false);
    await Future<void>.delayed(Duration.zero);
    expect(f.downloader.native, isEmpty);
    expect(await f.manifest.exists(), isFalse);
  });

  for (final childRecordPresent in [false, true]) {
    test('terminal cleanup keeps live native ownership with child record=$childRecordPresent', () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      final parent = (await f.downloader.database.recordForId(f.handle.taskId))!;
      await f.downloader.database.updateRecord(TaskRecord(parent.task, TaskStatus.complete, 1, 8));
      if (childRecordPresent) {
        await f.downloader.database.updateRecord(TaskRecord(f.child, TaskStatus.complete, 1, 4));
      }
      await expectLater(f.gateway.removeTracking(f.handle.taskId), throwsStateError);
      expect(await f.downloader.database.recordForId(f.handle.taskId), isNotNull);
      if (childRecordPresent) {
        expect(await f.downloader.database.recordForId(f.child.taskId), isNotNull);
      }
      expect(await f.part.readAsBytes(), [1, 2]);
      expect(await f.manifest.exists(), isTrue);
      f.downloader.native.clear();
      await f.gateway.removeTracking(f.handle.taskId);
      expect(await f.downloader.database.recordForId(f.handle.taskId), isNull);
    });
  }

  test('gateway accepted cancel waits for raw native writer settlement before range cleanup', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.downloader.keepCanceledWriterLive = true;
    var finished = false;
    Object? cancellationFailure;
    final cancellation = f.handle.cancel().then((accepted) {
      finished = true;
      return accepted;
    }, onError: (Object error, StackTrace _) {
      finished = true;
      cancellationFailure = error;
      return false;
    });
    try {
      await f.downloader.cancelEntered.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(finished, isFalse, reason: 'package acceptance cannot authorize range/checkpoint deletion');
      expect(f.handle.current.status, isNot(DownloadTransportStatus.canceled));
      expect(f.downloader.native.map((task) => task.taskId), contains(f.child.taskId));
      expect(await f.part.readAsBytes(), [1, 2]);
      expect(await f.manifest.exists(), isTrue);
    } finally {
      f.downloader.keepCanceledWriterLive = false;
      f.downloader.native.clear();
      await cancellation;
    }
    expect(finished, isTrue);
    expect(cancellationFailure, isNull, reason: 'the bounded gateway barrier must wait for actual settlement');
    expect(f.handle.current.status, DownloadTransportStatus.canceled);
    expect(await f.manifest.exists(), isFalse);
  });

  test('gateway stale paused row cannot hide its same-ID live native writer during cancellation', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.downloader.keepCanceledWriterLive = true;
    f.downloader.testStorage.paused.add(f.child);
    var finished = false;
    Object? cancellationFailure;
    final cancellation = f.handle.cancel().then((accepted) {
      finished = true;
      return accepted;
    }, onError: (Object error, StackTrace _) {
      finished = true;
      cancellationFailure = error;
      return false;
    });
    try {
      await f.downloader.cancelEntered.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(finished, isFalse, reason: 'a paused persistence occurrence cannot erase the separate native writer occurrence');
      expect(f.handle.current.status, isNot(DownloadTransportStatus.canceled));
      expect(f.downloader.native.map((task) => task.taskId), contains(f.child.taskId));
      expect(await f.part.readAsBytes(), [1, 2]);
      expect(await f.manifest.exists(), isTrue);
    } finally {
      f.downloader.keepCanceledWriterLive = false;
      f.downloader.native.clear();
      await cancellation;
    }
    expect(finished, isTrue);
    expect(cancellationFailure, isNull, reason: 'the bounded gateway barrier must wait for actual settlement');
    expect(f.handle.current.status, DownloadTransportStatus.canceled);
    expect(await f.manifest.exists(), isFalse);
  });

  test('gateway rejects a negative cancellation ACK even after raw native inventory becomes empty', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.downloader.native.clear();
    f.downloader.cancelAccepted = false;
    await expectLater(f.handle.cancel(), throwsA(isA<StateError>()));
    expect(f.downloader.cancelCalls, 1);
    expect(f.handle.current.status, isNot(DownloadTransportStatus.canceled));
    expect(await f.part.readAsBytes(), [1, 2]);
    expect(await f.manifest.exists(), isTrue);
  });

  for (final completed in [true, false]) {
    test('gateway restores exact ${completed ? 'complete' : 'incomplete'} durable parent without a manifest', () async {
      final root = await Directory.systemTemp.createTemp('aw-gateway-no-manifest-');
      final downloader = _Downloader();
      final parent = _parent(root);
      await File(await parent.filePath()).writeAsBytes(List<int>.filled(8, 7));
      await downloader.database.updateRecord(TaskRecord(
        parent, completed ? TaskStatus.complete : TaskStatus.paused, completed ? 1 : .5, 8,
      ));
      final gateway = _gateway(downloader);
      final handle = (await gateway.attach(parent.taskId))!;
      try {
        expect(handle.current.status, completed ? DownloadTransportStatus.complete : DownloadTransportStatus.missing);
        expect(await File(await parent.filePath()).readAsBytes(), List<int>.filled(8, 7));
        expect(downloader.cancelCalls, 0);
        expect(await Directory('${await parent.filePath()}.parts').exists(), isFalse);
      } finally {
        await handle.cancel();
        await downloader.updatesController.close();
        downloader.database.destroy();
        await root.delete(recursive: true);
      }
    });
  }

  for (final ios in [false, true]) {
    test('gateway injected iOS=$ios preserves only the platform-authoritative package parallel metrics', () async {
      final downloader = _Downloader();
      final task = ParallelDownloadTask(
        taskId: 'ordinary-parallel-metrics', url: 'https://example.test/video',
        filename: 'video.mp4', chunks: 2, group: kDownloadV2PackageGroup,
      );
      final transfer = Transfer(task, downloader);
      transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.running));
      transfer.updateProgress(TaskProgressUpdate(task, .25, 400, 12.5, const Duration(seconds: 24)));
      downloader.testTransfers.handles[task.taskId] = transfer;
      final gateway = _gateway(downloader, ios: ios);
      try {
        final handle = (await gateway.attach(task.taskId))!;
        expect(handle.current.networkSpeedMBps, ios ? -1 : 12.5);
        expect(handle.current.timeRemaining, ios ? Duration.zero : const Duration(seconds: 24));
        expect(handle.current.status, DownloadTransportStatus.running);
        expect(handle.current.progress, .25);
        expect(handle.current.transferredBytes, isNull);
      } finally {
        await gateway.removeTracking(task.taskId);
        await downloader.updatesController.close();
        downloader.database.destroy();
      }
    });
  }

  test('actual iOS gateway stores signed range checkpoint only in private ApplicationSupport', () async {
    final f = await _startPrivateCheckpoint();
    expect(await File('${f.destination}.parts/manifest.json').exists(), isFalse);
    expect(await File('${f.destination}.parts/manifest.json.tmp').exists(), isFalse);
    expect(await f.privateManifest.exists(), isTrue);
    final checkpoint = await f.privateManifest.readAsString();
    expect(checkpoint, contains('signed-secret'));
    expect(checkpoint, contains('session-cookie-secret'));
    await for (final entry in f.visible.list(recursive: true, followLinks: false)) {
      if (entry is File) {
        expect(utf8.decode(await entry.readAsBytes(), allowMalformed: true), isNot(contains('session-cookie-secret')));
      }
    }
  });

  test('actual iOS gateway reconstructs exact private checkpoint when package parent DB record is absent', () async {
    final f = await _startPrivateCheckpoint();
    await f.downloader.database.deleteRecordsWithIds([f.handle.taskId]);
    final replacement = _gateway(f.downloader);
    final restored = await replacement.rehydrate();
    final matching = restored.where((handle) => handle.taskId == f.handle.taskId).toList();
    try {
      expect(matching, hasLength(1), reason: 'private recovery inventory must be a production gateway input');
      expect(matching.single.current.totalBytes, 8);
      expect(matching.single.current.status, isNot(DownloadTransportStatus.complete));
      expect(await f.privateManifest.exists(), isTrue);
      expect(f.downloader.native.map((task) => task.taskId).toSet().length, 2);
    } finally {
      for (final handle in matching) { await handle.cancel(); }
    }
  });

  for (final linked in ['ancestor', 'owner', 'leaf']) {
    test('private resolver rejects a linked $linked without touching foreign bytes', () async {
      final root = await Directory.systemTemp.createTemp('aw-private-linked-owner-');
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _PrivatePaths(root.path, root.path, root.path);
      try {
        final foreign = await Directory(p.join(root.path, 'foreign')).create();
        final sentinel = await File(p.join(foreign.path, 'manifest.json')).writeAsString('foreign-secret');
        final task = DownloadTask(taskId: 'linked-owner', url: 'https://example.test/video', filename: 'video.mp4');
        final ranges = Directory(p.join(root.path, 'download_v2', 'ranges'));
        if (linked == 'ancestor') {
          await Link(p.join(root.path, 'download_v2')).create(foreign.path);
        } else {
          await ranges.create(recursive: true);
          final owner = p.join(ranges.path, sha256.convert(utf8.encode(task.taskId)).toString());
          if (linked == 'owner') {
            await Link(owner).create(foreign.path);
          } else {
            await Directory(owner).create();
            await Link(p.join(owner, 'manifest.json')).create(sentinel.path);
          }
        }
        await expectLater(privateParallelManifestFileV2(task), throwsA(isA<FileSystemException>()));
        expect(await sentinel.readAsString(), 'foreign-secret');
      } finally {
        PathProviderPlatform.instance = previousPaths;
        await root.delete(recursive: true);
      }
    });
  }

  for (final errno in <Object?>[17, 28, 95, 18, null, false]) {
    test('exclusive bridge ${errno ?? 'unavailable'} preserves source and foreign final', () async {
      final root = await Directory.systemTemp.createTemp('aw-native-promotion-contract-');
      final source = await File(p.join(root.path, 'verified.tmp')).writeAsBytes([1, 2, 3]);
      final target = await File(p.join(root.path, 'foreign.mp4')).writeAsBytes([]);
      const channel = MethodChannel('com.animewitcher.app/download_continued_processing');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var invoked = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        invoked = true;
        expect(call.method, 'promoteCompletedFile');
        expect(call.arguments, {'sourcePath': source.path, 'targetPath': target.path, 'expectedBytes': 3});
        if (errno == false) return false;
        if (errno == null) throw MissingPluginException();
        throw PlatformException(code: 'PROMOTION_FAILED', details: {'errno': errno});
      });
      try {
        await expectLater(promoteCompletedDownloadFileV2(source, target, 3),
          throwsA(isA<FileSystemException>().having((error) => error.osError?.errorCode, 'errno', errno == false ? null : errno ?? 95)));
        expect(invoked, isTrue);
        expect(await source.readAsBytes(), [1, 2, 3]);
        expect(await target.readAsBytes(), isEmpty);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      }
    });
  }

  test('ordinary package HTTP404 is terminal source expiry rather than missing local identity', () {
    final task = DownloadTask(taskId: 'http404-exact-task', url: 'https://example.test/video', filename: 'video.mp4');
    final transfer = Transfer(task);
    try {
      transfer.updateStatus(TaskStatusUpdate(task, TaskStatus.notFound));
      final snapshot = packageTransportSnapshotForV2(transfer);
      expect(snapshot.status, DownloadTransportStatus.failed);
      expect(snapshot.failureCategory, DownloadFailureCategory.sourceExpired);
    } finally {
      transfer.dispose();
    }
  });
}

PackageBackgroundDownloaderGateway _gateway(_Downloader downloader, {bool ios = true, Future<void> Function(String)? discard}) =>
    PackageBackgroundDownloaderGateway(
      discardDurableResumeCheckpoint: discard,
      downloader: downloader, initializePackage: () async {}, isIOS: () => ios,
      notificationPreferences: () => DownloadNotificationPrefs.disabled,
    );

ParallelDownloadTask _parent(Directory root) => ParallelDownloadTask(
  taskId: 'gateway-owned-parent', url: 'https://example.test/video', filename: 'video.mp4',
  directory: root.path, baseDirectory: BaseDirectory.root,
  group: kDownloadV2DurableParallelGroup, chunks: 2, allowPause: true,
);

final class _Fixture {
  _Fixture(this.root, this.downloader, this.child, this.part, this.manifest, this.handle, this.gateway);
  final Directory root;
  final _Downloader downloader;
  final DownloadTask child;
  final File part;
  final File manifest;
  final DownloadTransportHandle handle;
  final PackageBackgroundDownloaderGateway gateway;
  static Future<_Fixture> create({bool completedSibling = false, bool discard = false}) async {
    final root = await Directory.systemTemp.createTemp('aw-gateway-owned-range-');
    final parent = _parent(root);
    final parts = await Directory('${await parent.filePath()}.parts').create();
    final children = [
      for (var index = 0; index < 2; index++) DownloadTask(
        taskId: '${parent.taskId}.part.$index', url: parent.url, filename: '$index.part',
        directory: parts.path, baseDirectory: BaseDirectory.root, group: 'animewitcher_parts',
        headers: {'Range': 'bytes=${index * 4}-${index * 4 + 3}'},
        metaData: jsonEncode({'parentTaskId': parent.taskId, 'attemptGeneration': 1}),
      ),
    ];
    final part = await File(await children.first.filePath()).writeAsBytes([1, 2]);
    if (completedSibling) {
      await File(await children.last.filePath()).writeAsBytes([5, 6, 7, 8], flush: true);
    }
    await File(p.join(parts.path, 'manifest.json')).writeAsString(jsonEncode({
      'schemaVersion': 2, 'parentTaskId': parent.taskId, 'generation': 1,
      'checkpointSequence': 1, 'expectedBytes': 8, 'totalBytes': 8,
      'parts': [
        for (var index = 0; index < 2; index++) {
          'task': children[index].toJson(), 'from': index * 4, 'to': index * 4 + 3,
          'progress': index == 0 ? .5 : (completedSibling ? 1.0 : 0.0),
          'credibleProgress': index == 0 ? .5 : (completedSibling ? 1.0 : 0.0),
          'durableBytes': index == 1 && completedSibling ? 4 : 0,
          'complete': index == 1 && completedSibling, 'attemptGeneration': 1,
        },
      ],
    }));
    final downloader = _Downloader()..native.add(children.first);
    await downloader.database.updateRecord(TaskRecord(parent, TaskStatus.paused, .25, 8));
    final gateway = _gateway(downloader, discard: discard ? (id) async {
      await downloader.testStorage.removeResumeData(id);
      await downloader.testStorage.removePausedTask(id);
    } : null);
    final handle = (await gateway.attach(parent.taskId))!;
    final checkpoint = await privateParallelManifestFileV2(parent);
    return _Fixture(root, downloader, children.first, part, checkpoint, handle, gateway);
  }
  Future<void> dispose() async {
    downloader.cancelAccepted = true;
    downloader.keepCanceledWriterLive = false;
    downloader.unknownLiveness = false;
    downloader.native.clear();
    await handle.cancel();
    await downloader.updatesController.close();
    downloader.database.destroy();
    await root.delete(recursive: true);
  }
}

final class _Downloader implements FileDownloader {
  _Downloader() : database = Database(_Storage()) { transfers = _Transfers(this); }
  @override
  final Database database;
  @override
  late Transfers transfers;
  _Transfers get testTransfers => transfers as _Transfers;
  _Storage get testStorage => database.storage as _Storage;
  final updatesController = StreamController<TaskUpdate>.broadcast();
  final native = <Task>[];
  bool cancelAccepted = true;
  bool keepCanceledWriterLive = false;
  bool unknownLiveness = false;
  Future<bool>? cancelAck;
  Future<bool>? enqueueAck;
  bool commitBeforeEnqueueAck = false;
  final enqueueEntered = Completer<void>();
  Future<bool>? canResumeAck;
  final resumeStateEntered = Completer<void>();
  int enqueueCalls = 0;
  int resumeCalls = 0;
  final resumedIds = <String>[];
  int pauseCalls = 0;
  bool pauseAccepted = true;
  bool stopOnRejectedPause = false;
  bool keepResumeData = true;
  Future<void>? pauseCheckpointGate;
  Future<void>? pauseAckGate;
  bool stopBeforePauseAck = false;
  final pauseEntered = Completer<void>();
  final pauseStored = Completer<void>();
  int cancelCalls = 0;
  final cancelEntered = Completer<void>();
  final twoNativeStarts = Completer<void>();
  @override
  Stream<TaskUpdate> get updates => updatesController.stream;
  @override
  Future<bool> cancelTasksWithIds(Iterable<String> taskIds) async {
    cancelCalls++;
    if (!cancelEntered.isCompleted) cancelEntered.complete();
    if (cancelAck != null) return cancelAck!;
    if (cancelAccepted && !keepCanceledWriterLive) native.removeWhere((task) => taskIds.contains(task.taskId));
    return cancelAccepted;
  }
  @override
  Future<bool> taskCanResume(Task task) async {
    if (!resumeStateEntered.isCompleted) resumeStateEntered.complete();
    return await canResumeAck ?? testStorage.resumeData.containsKey(task.taskId);
  }
  @override
  Future<bool> pause(DownloadTask task) async {
    pauseCalls++;
    if (!pauseEntered.isCompleted) pauseEntered.complete();
    if (stopBeforePauseAck) native.removeWhere((item) => item.taskId == task.taskId);
    await pauseAckGate;
    if (!pauseAccepted) {
      if (stopOnRejectedPause) native.removeWhere((item) => item.taskId == task.taskId);
      return false;
    }
    native.removeWhere((item) => item.taskId == task.taskId);
    if (keepResumeData) {
      void store() {
        testStorage.paused.removeWhere((item) => item.taskId == task.taskId);
        testStorage.paused.add(task);
        testStorage.resumeData[task.taskId] = ResumeData(task, 'opaque-native-resume-data');
        testStorage.records[task.taskId] = TaskRecord(task, TaskStatus.paused, 0, 4);
        if (!pauseStored.isCompleted) pauseStored.complete();
      }
      final pending = pauseCheckpointGate;
      if (pending == null) { store(); } else { unawaited(pending.then((_) => store())); }
    }
    return true;
  }
  @override
  Future<bool> resume(DownloadTask task) {
    resumeCalls++;
    resumedIds.add(task.taskId);
    return enqueue(task);
  }
  @override
  Future<bool> enqueue(Task task) async {
    enqueueCalls++;
    if (!enqueueEntered.isCompleted) enqueueEntered.complete();
    if (commitBeforeEnqueueAck) native.add(task);
    final ack = await enqueueAck;
    if (ack == false) return false;
    if (commitBeforeEnqueueAck) return true;
    native.add(task);
    if (native.length >= 2 && !twoNativeStarts.isCompleted) twoNativeStarts.complete();
    return true;
  }
  @override
  Future<List<Task>> allTasks({String group = FileDownloader.defaultGroup,
    bool includeTasksWaitingToRetry = true, bool allGroups = false,
  }) async {
    if (unknownLiveness) throw StateError('test-only raw native ownership unavailable');
    // The package concatenates persisted paused tasks before native tasks.
    return [for (final task in [...testStorage.paused, ...native])
      if (allGroups || task.group == group) task];
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transfers implements Transfers {
  _Transfers(this.downloader);
  @override
  final _Downloader downloader;
  final handles = <String, Transfer>{};
  @override
  Future<List<Transfer>> rehydrateFromDatabase({String? group}) async =>
      [for (final handle in handles.values) if (group == null || handle.task.group == group) handle];
  @override
  Transfer? forId(String taskId) => handles[taskId];
  @override
  Transfer? remove(String taskId, {bool dispose = true}) {
    final transfer = handles.remove(taskId);
    if (dispose) transfer?.dispose();
    return transfer;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Storage implements PersistentStorage {
  final records = <String, TaskRecord>{};
  final paused = <Task>[];
  final resumeData = <String, ResumeData>{};
  Future<void> Function(TaskRecord)? onStoreRecord;
  @override
  Future<void> storeTaskRecord(TaskRecord record) async {
    await onStoreRecord?.call(record);
    records[record.taskId] = record;
  }
  @override
  Future<TaskRecord?> retrieveTaskRecord(String id) async => records[id];
  @override
  Future<List<TaskRecord>> retrieveAllTaskRecords() async => records.values.toList();
  @override
  Future<void> removeTaskRecord(String? id) async {
    if (id == null) { records.clear(); } else { records.remove(id); }
  }
  @override
  Future<List<Task>> retrieveAllPausedTasks() async => [...paused];
  @override
  Future<ResumeData?> retrieveResumeData(String id) async => resumeData[id];
  @override
  Future<Task?> retrievePausedTask(String id) async =>
      paused.where((task) => task.taskId == id).firstOrNull;
  @override
  Future<void> removeResumeData(String? id) async {
    if (id == null) { resumeData.clear(); } else { resumeData.remove(id); }
  }
  @override
  Future<void> removePausedTask(String? id) async {
    if (id == null) { paused.clear(); } else { paused.removeWhere((task) => task.taskId == id); }
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<({Directory visible, String destination, File privateManifest, _Downloader downloader, DownloadTransportHandle handle})> _startPrivateCheckpoint() async {
  final root = await Directory.systemTemp.createTemp('aw-private-gateway-');
  final support = await Directory(p.join(root.path, 'support')).create();
  final visible = await Directory(p.join(root.path, 'visible')).create();
  final previousPaths = PathProviderPlatform.instance;
  PathProviderPlatform.instance = _PrivatePaths(support.path, visible.path, root.path);
  const id = 'private-gateway-exact-parent';
  final destination = p.join(visible.path, 'video.mp4');
  final downloader = _Downloader();
  final gateway = PackageBackgroundDownloaderGateway(
    downloader: downloader, initializePackage: () async {}, isIOS: () => true,
    notificationPreferences: () => DownloadNotificationPrefs.disabled,
    rangeCapabilityProbe: (_) async => (supportsRanges: true, totalBytes: 8),
  );
  DownloadTransportHandle? handle;
  addTearDown(() async {
    try {
      downloader.keepCanceledWriterLive = false;
      downloader.native.clear();
      await handle?.cancel();
      await downloader.updatesController.close();
      downloader.database.destroy();
    } finally {
      PathProviderPlatform.instance = previousPaths;
      await root.delete(recursive: true);
    }
  });
  handle = await gateway.start(DownloadTaskSpecV2(
    taskId: id, url: 'https://example.test/video?signed-secret',
    destinationPath: destination, headers: const {'Cookie': 'session-cookie-secret'},
    allowPause: true, retries: 2, parallelChunks: 2, expectedBytes: 8,
  ));
  downloader.updatesController.add(TaskStatusUpdate(downloader.native.single, TaskStatus.running));
  await downloader.twoNativeStarts.future.timeout(const Duration(seconds: 5));
  return (visible: visible, destination: destination,
    privateManifest: File(p.join(support.path, 'download_v2', 'ranges', sha256.convert(utf8.encode(id)).toString(), 'manifest.json')),
    downloader: downloader, handle: handle);
}

final class _PrivatePaths extends PathProviderPlatform {
  _PrivatePaths(this.support, this.documents, this.temporary);
  final String support;
  final String documents;
  final String temporary;
  @override
  Future<String?> getApplicationSupportPath() async => support;
  @override
  Future<String?> getApplicationDocumentsPath() async => documents;
  @override
  Future<String?> getTemporaryPath() async => temporary;
  @override
  Future<String?> getApplicationCachePath() async => temporary;
  @override
  Future<String?> getDownloadsPath() async => documents;
  @override
  Future<String?> getLibraryPath() async => support;
}
