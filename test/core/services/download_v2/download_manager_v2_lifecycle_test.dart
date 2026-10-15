import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_continued_processing_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:background_downloader/background_downloader.dart'
    show TaskStatus;
import 'package:flutter_test/flutter_test.dart';

import 'download_v2_test_support.dart';
import '../../../support/widget_completion.dart';

void main() {
  test('artifact deletion failure stays retryable after successful cancellation', () async {
    final root = await Directory.systemTemp.createTemp('aw-artifact-delete-retry-');
    final f = _fixture(destinationPath: '${root.path}/episode.mp4');
    addTearDown(f.manager.dispose);
    addTearDown(() async {
      await Process.run('chmod', ['700', root.path]);
      await root.delete(recursive: true);
    });
    await f.manager.start(f.request);
    final file = await File(f.request.destinationPath).writeAsBytes([1, 2, 3]);
    expect((await Process.run('chmod', ['500', root.path])).exitCode, 0);
    await expectLater(f.manager.delete(f.request.logicalId), throwsA(isA<FileSystemException>()));
    expect((await f.store.get(f.request.logicalId))?.intent, DownloadUserIntent.canceled);
    expect((await f.store.get(f.request.logicalId))?.failureCategory, DownloadFailureCategory.filesystem);
    expect(f.manager.snapshotFor(f.request.logicalId)?.status, DownloadTransportStatus.failed);
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect((await Process.run('chmod', ['700', root.path])).exitCode, 0);
    await f.manager.delete(f.request.logicalId);
    expect(await f.store.get(f.request.logicalId), isNull);
    expect(await file.exists(), isFalse);
    expect(f.gateway.startedSpecs, hasLength(1));
  }, skip: Platform.isWindows);

  test('cleanup failure retains canceled ownership as retryable failure without reviving transfer', () async {
    final root = await Directory.systemTemp.createTemp('aw-cleanup-retry-');
    final f = _fixture(destinationPath: '${root.path}/episode.mp4');
    addTearDown(f.manager.dispose);
    addTearDown(() => root.delete(recursive: true));
    await f.manager.start(f.request);
    final file = await File(f.request.destinationPath).writeAsBytes([1, 2, 3]);
    f.gateway.onRemoveTracking = (_) async => throw StateError('native ownership inventory unavailable');
    await expectLater(f.manager.delete(f.request.logicalId), throwsStateError);
    final retained = (await f.store.get(f.request.logicalId))!;
    expect(retained.intent, DownloadUserIntent.canceled);
    expect(retained.failureCategory, DownloadFailureCategory.filesystem);
    expect(f.manager.snapshotFor(f.request.logicalId)?.status, DownloadTransportStatus.failed);
    expect(await file.readAsBytes(), [1, 2, 3]);
    f.gateway.onRemoveTracking = null;
    await f.manager.delete(f.request.logicalId);
    expect(await f.store.get(f.request.logicalId), isNull);
    expect(await file.exists(), isFalse);
    expect(f.gateway.startedSpecs, hasLength(1));
  });

  testWidgets(
    'unknown resume acknowledgement blocks destructive cleanup until settled',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('aw-v2-late-resume-');
      final destination = File('${temp.path}/episode.mp4')
        ..writeAsBytesSync([1, 2, 3]);
      final f = _fixture(destinationPath: destination.path);
      StreamSubscription<List<LogicalDownloadRecordV2>>? records;
      final acknowledgement = Completer<bool>();
      try {
        await pumpUntilFuture(
          tester,
          f.manager.start(f.request),
          'start before uncertain resume',
        );
        final taskId = f.gateway.startedSpecs.single.taskId;
        final handle = f.gateway.handleFor(taskId)!;
        await pumpUntilFuture(
          tester,
          f.manager.pause(f.request.logicalId),
          'pause before uncertain resume',
        );
        var nativeWriter = false;
        handle.onResume = () async {
          final accepted = await acknowledgement.future;
          nativeWriter = accepted;
          return accepted;
        };
        handle.onCancel = () async {
          nativeWriter = false;
          handle.emit(DownloadTransportStatus.canceled);
          return true;
        };
        Object? resumeError;
        f.manager
            .resume(f.request.logicalId)
            .then<void>(
              (_) {},
              onError: (Object error) {
                resumeError = error;
              },
            ).ignore();
        await pumpUntil(
          tester,
          () => handle.resumeCalls == 1,
          'native resume request',
        );
        await tester.pump(const Duration(seconds: 31));
        expect(resumeError, isA<StateError>());
        handle.emit(DownloadTransportStatus.canceled);
        expect(
          f.manager.snapshotFor(f.request.logicalId)?.status,
          DownloadTransportStatus.held,
        );
        var canceledIntent = false;
        records = f.manager.records.listen((values) {
          canceledIntent = values.any(
            (record) => record.intent == DownloadUserIntent.canceled,
          );
        });
        Object? deleteError;
        f.manager
            .delete(f.request.logicalId)
            .then<void>(
              (_) {},
              onError: (Object error) {
                deleteError = error;
              },
            ).ignore();
        await pumpUntil(
          tester,
          () => canceledIntent,
          'durable cancel intent before cleanup',
        );
        await tester.pump(const Duration(seconds: 31));
        expect(deleteError, isA<StateError>());
        expect(destination.existsSync(), isTrue);
        expect(f.gateway.removedTracking, isEmpty);
        expect(
          handle.cancelCalls,
          0,
          reason: 'resume may still create a native writer',
        );
        expect(
          f.manager.snapshotFor(f.request.logicalId)?.status,
          DownloadTransportStatus.held,
        );

        acknowledgement.complete(true);
        await tester.pump();
        expect(
          nativeWriter,
          isTrue,
          reason: 'late native commit can precede its progress callback',
        );
        await pumpUntilFuture(
          tester,
          f.manager.delete(f.request.logicalId),
          'retry deletion after resume acknowledgement',
        );
        expect(handle.cancelCalls, 1);
        expect(nativeWriter, isFalse);
        expect(destination.existsSync(), isFalse);
        expect(
          await pumpUntilFuture(
            tester,
            f.store.get(f.request.logicalId),
            'deleted logical record',
          ),
          isNull,
        );
        handle.emit(DownloadTransportStatus.running);
        await tester.pump();
        expect(f.manager.snapshotFor(f.request.logicalId), isNull);
      } finally {
        if (!acknowledgement.isCompleted) acknowledgement.complete(false);
        if (records != null) {
          await pumpUntilFuture(
            tester,
            records.cancel(),
            'uncertain resume records cancellation',
          );
        }
        await pumpUntilFuture(
          tester,
          f.manager.dispose(),
          'uncertain resume manager disposal',
        );
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
  );

  test(
    'final snapshot with active native connections still requires cancel',
    () async {
      final temp = Directory.systemTemp.createTempSync('aw-v2-final-live-');
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final f = _fixture(destinationPath: '${temp.path}/episode.mp4');
      addTearDown(f.manager.dispose);
      await f.manager.start(f.request);
      final taskId = f.gateway.startedSpecs.single.taskId;
      final handle = f.gateway.handleFor(taskId)!;
      handle.emitSnapshot(
        DownloadTransportSnapshot(
          taskId: taskId,
          status: DownloadTransportStatus.failed,
          progress: .5,
          activeConnections: 1,
        ),
      );

      await f.manager.delete(f.request.logicalId);

      expect(handle.cancelCalls, 1);
      expect(await f.store.get(f.request.logicalId), isNull);
    },
  );

  for (final action in ['pause', 'cancel']) {
    testWidgets('$action settlement timeout retains requested intent', (
      tester,
    ) async {
      final f = _fixture();
      try {
        await pumpUntilFuture(
          tester,
          f.manager.start(f.request),
          'start before settlement timeout',
        );
        final handle = f.gateway.handleFor(
          f.gateway.startedSpecs.single.taskId,
        )!;
        if (action == 'pause') {
          handle.onPause = () async => true;
        } else {
          handle.onCancel = () async => true;
        }
        Object? controlError;
        final Future<Object?> command = action == 'pause'
            ? f.manager.pause(f.request.logicalId)
            : f.manager.cancel(f.request.logicalId);
        command
            .then<void>(
              (_) {},
              onError: (Object error) {
                controlError = error;
              },
            )
            .ignore();
        await pumpUntil(
          tester,
          () => handle.pauseCalls + handle.cancelCalls == 1,
          'accepted native control',
        );
        await tester.pump(const Duration(seconds: 11));
        await pumpUntil(
          tester,
          () => controlError != null,
          'control timeout projection',
        );
        expect(controlError, isA<StateError>());
        final record = await pumpUntilFuture(
          tester,
          f.store.get(f.request.logicalId),
          'retained intent after timeout',
        );
        expect(
          record?.intent,
          action == 'pause'
              ? DownloadUserIntent.paused
              : DownloadUserIntent.canceled,
        );
        expect(
          f.manager.snapshotFor(f.request.logicalId)?.status,
          DownloadTransportStatus.running,
        );
        handle.emit(
          action == 'pause'
              ? DownloadTransportStatus.paused
              : DownloadTransportStatus.canceled,
        );
        await tester.pump();
        final settled = await pumpUntilFuture(
          tester,
          f.store.get(f.request.logicalId),
          'late control settlement',
        );
        expect(settled?.intent, record?.intent);
      } finally {
        await pumpUntilFuture(
          tester,
          f.manager.dispose(),
          'settlement timeout manager disposal',
        );
      }
    });
  }

  testWidgets('lost pause acknowledgement releases the queue for deletion', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('aw-v2-lost-pause-');
    final diagnostics = InMemoryDownloadDiagnosticsV2();
    final f = _fixture(
      diagnostics: diagnostics,
      destinationPath: '${temp.path}/episode.mp4',
    );
    final acknowledgement = Completer<bool>();
    try {
      await pumpUntilFuture(
        tester,
        f.manager.start(f.request),
        'start before lost pause reply',
      );
      final taskId = f.gateway.startedSpecs.single.taskId;
      final handle = f.gateway.handleFor(taskId)!;
      handle.onPause = () async {
        final accepted = await acknowledgement.future;
        if (accepted) handle.emit(DownloadTransportStatus.paused);
        return accepted;
      };
      Object? pauseError;
      f.manager
          .pause(f.request.logicalId)
          .then<void>(
            (_) {},
            onError: (Object error) {
              pauseError = error;
            },
          )
          .ignore();
      await pumpUntil(
        tester,
        () => handle.pauseCalls == 1,
        'native pause request',
      );
      await tester.pump(const Duration(seconds: 31));
      await pumpUntil(
        tester,
        () => pauseError != null,
        'pause timeout projection',
      );
      expect(pauseError, isA<StateError>());
      final commands = diagnostics.transportEvents
          .where((event) => event['action'] == 'pause')
          .toList();
      expect(commands.map((event) => event['event']), [
        'command.requested',
        'command.started',
        'command.timedOut',
      ]);
      expect(commands.last['logicalId'], f.request.logicalId.value);
      expect(commands.last['taskId'], taskId);
      expect(commands.last['durationMs'], greaterThanOrEqualTo(0));
      expect(
        f.manager.snapshotFor(f.request.logicalId)?.status,
        DownloadTransportStatus.running,
      );
      final record = await pumpUntilFuture(
        tester,
        f.store.get(f.request.logicalId),
        'intent after lost pause reply',
      );
      expect(record?.intent, DownloadUserIntent.paused);
      await pumpUntilFuture(
        tester,
        f.manager.delete(f.request.logicalId),
        'deletion after lost pause reply',
      );
      expect(handle.cancelCalls, 1);
      expect(
        await pumpUntilFuture(
          tester,
          f.store.get(f.request.logicalId),
          'deleted logical record',
        ),
        isNull,
      );
      expect(diagnostics.transportEvents.last['taskId'], taskId);
      acknowledgement.complete(true);
      await tester.pump();
      expect(f.manager.snapshotFor(f.request.logicalId), isNull);
    } finally {
      if (!acknowledgement.isCompleted) acknowledgement.complete(false);
      await pumpUntilFuture(
        tester,
        f.manager.dispose(),
        'lost pause manager disposal',
      );
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    }
  });

  test('control rejection diagnostics never include exception text', () async {
    final diagnostics = InMemoryDownloadDiagnosticsV2();
    final f = _fixture(diagnostics: diagnostics);
    addTearDown(f.manager.dispose);
    await f.manager.start(f.request);
    final handle = f.gateway.handleFor(f.gateway.startedSpecs.single.taskId)!;
    handle.onPause = () async =>
        throw StateError('https://secret.invalid?token=private');

    await expectLater(f.manager.pause(f.request.logicalId), throwsStateError);

    final commands = diagnostics.transportEvents
        .where((event) => event['action'] == 'pause')
        .toList();
    expect(commands.map((event) => event['event']), [
      'command.requested',
      'command.started',
      'command.rejected',
    ]);
    expect(commands.last['errorType'], isNotNull);
    expect(commands.toString(), isNot(contains('private')));
    expect(commands.toString(), isNot(contains('secret.invalid')));
  });

  test(
    'cancel timeout retains intent through late native settlement',
    () async {
      final f = _fixture();
      addTearDown(f.manager.dispose);
      await f.manager.start(f.request);
      final taskId = f.gateway.startedSpecs.single.taskId;
      final handle = f.gateway.handleFor(taskId)!;
      handle.onCancel = () async =>
          throw TimeoutException('native acknowledgement');

      await expectLater(
        f.manager.cancel(f.request.logicalId),
        throwsA(isA<TimeoutException>()),
      );

      expect(
        (await f.store.get(f.request.logicalId))?.intent,
        DownloadUserIntent.canceled,
      );
      expect(
        f.manager.snapshotFor(f.request.logicalId)?.status,
        DownloadTransportStatus.running,
      );
      expect(f.gateway.removedTracking, isEmpty);
      handle.emit(DownloadTransportStatus.canceled);
      expect(
        (await f.store.get(f.request.logicalId))?.intent,
        DownloadUserIntent.canceled,
      );
      final recovered = DownloadManagerV2(
        store: f.store,
        gateway: f.gateway,
        sourceResolver: StaticSourceResolverV2(),
      );
      addTearDown(recovered.dispose);
      await recovered.initialize();
      expect(
        f.gateway.startedSpecs,
        hasLength(1),
        reason: 'a late successful cancel must never restart on recovery',
      );
    },
  );

  test('pause timeout retains intent without hiding a live writer', () async {
    final f = _fixture();
    addTearDown(f.manager.dispose);
    await f.manager.start(f.request);
    final handle = f.gateway.handleFor(f.gateway.startedSpecs.single.taskId)!;
    handle.onPause = () async =>
        throw TimeoutException('native acknowledgement');

    await expectLater(
      f.manager.pause(f.request.logicalId),
      throwsA(isA<TimeoutException>()),
    );

    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.paused,
    );
    expect(
      f.manager.snapshotFor(f.request.logicalId)?.status,
      DownloadTransportStatus.running,
    );
    handle.emit(DownloadTransportStatus.paused);
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.paused,
    );
    expect(
      f.manager.snapshotFor(f.request.logicalId)?.status,
      DownloadTransportStatus.paused,
    );
  });

  test('cancel keeps live presentation until transport settlement', () async {
    final observer = _RecordingPresentationObserver();
    final f = _fixture(presentationObservers: [observer]);
    addTearDown(f.manager.dispose);
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;
    final entered = Completer<void>();
    handle.onCancel = () async {
      entered.complete();
      return true;
    };
    final cancellation = f.manager.cancel(f.request.logicalId);
    await entered.future;
    try {
      expect(
        (await f.store.get(f.request.logicalId))?.intent,
        DownloadUserIntent.canceled,
        reason: 'user intent is durable before the transport stops',
      );
      expect(
        f.manager.snapshotFor(f.request.logicalId)?.status,
        DownloadTransportStatus.running,
      );
      expect(observer.events.last.$2.status, DownloadTransportStatus.running);
    } finally {
      handle.emit(DownloadTransportStatus.canceled);
      await cancellation;
    }
    expect(observer.events.last.$2.status, DownloadTransportStatus.canceled);
  });

  test(
    'accepted V2 snapshots are forwarded to presentation observers',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _FakeGateway();
      final resolver = StaticSourceResolverV2();
      final observer = _RecordingPresentationObserver();
      final logicalId = logicalDownloadIdFor(
        animeId: 'anilist:21',
        episodeKey: '12',
        variantKey: 'sub:1080p',
      );
      final request = DownloadStartRequestV2(
        logicalId: logicalId,
        mediaId: 'anilist:21',
        unitKey: '12',
        variantKey: 'sub:1080p',
        destinationPath: 'downloads/anime/episode-12.mp4',
        sourceDescriptor: const <String, Object?>{
          'providerId': 'provider.example',
        },
        allowPause: true,
        retries: 2,
        parallelChunks: 1,
      );
      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
        presentationObservers: <DownloadPresentationObserverV2>[observer],
      );
      addTearDown(manager.dispose);

      await manager.start(request);
      final taskId = gateway.startedSpecs.single.taskId;
      gateway.emit(taskId, DownloadTransportStatus.running);
      await Future<void>.delayed(Duration.zero);

      expect(observer.events, isNotEmpty);
      expect(observer.events.last.$1.logicalId, logicalId);
      expect(observer.events.last.$2.taskId, taskId);
      expect(observer.events.last.$2.status, DownloadTransportStatus.running);
    },
  );

  test(
    'native observed speed updates only the current V2 generation',
    () async {
      final f = _fixture();
      await f.manager.start(f.request);
      final taskId = f.gateway.startedSpecs.single.taskId;

      f.manager.observeNativeNetworkSpeed(
        taskId: taskId,
        bytesPerSecond: 4_500_000,
      );

      expect(f.manager.snapshotFor(f.request.logicalId)?.networkSpeedMBps, 4.5);

      f.manager.observeNativeNetworkSpeed(taskId: taskId, bytesPerSecond: 0);
      expect(f.manager.snapshotFor(f.request.logicalId)?.networkSpeedMBps, 0);

      await f.manager.cancel(f.request.logicalId);
      f.manager.observeNativeNetworkSpeed(
        taskId: taskId,
        bytesPerSecond: 99_000_000,
      );

      expect(
        f.manager.snapshotFor(f.request.logicalId)?.networkSpeedMBps,
        isNot(99.0),
      );
    },
  );

  test('parallel parent progress does not erase native speed', () async {
    final f = _fixture(parallelChunks: 4);
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;

    f.manager.observeNativeNetworkSpeed(
      taskId: taskId,
      bytesPerSecond: 4_500_000,
    );
    handle.emitSnapshot(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: 0.5,
        transferredBytes: 50,
        totalBytes: 100,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final snapshot = f.manager.snapshotFor(f.request.logicalId);
    expect(snapshot?.progress, 0.5);
    expect(snapshot?.networkSpeedMBps, 4.5);
  });

  test('zero native speed clears ETA without dividing by zero', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _FakeGateway();
    final resolver = StaticSourceResolverV2();
    final logicalId = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );
    final request = DownloadStartRequestV2(
      logicalId: logicalId,
      mediaId: 'anilist:21',
      unitKey: '12',
      variantKey: 'sub:1080p',
      destinationPath: 'downloads/anime/episode-12.mp4',
      sourceDescriptor: const <String, Object?>{
        'providerId': 'provider.example',
      },
      expectedBytes: 1000,
      allowPause: true,
      retries: 2,
      parallelChunks: 16,
    );
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    addTearDown(manager.dispose);

    await manager.start(request);
    final taskId = gateway.startedSpecs.single.taskId;
    gateway
        .handleFor(taskId)!
        .emitSnapshot(
          DownloadTransportSnapshot(
            taskId: taskId,
            status: DownloadTransportStatus.running,
            progress: 0.5,
            transferredBytes: 500,
            totalBytes: 1000,
          ),
        );

    expect(
      () =>
          manager.observeNativeNetworkSpeed(taskId: taskId, bytesPerSecond: 0),
      returnsNormally,
    );
    expect(manager.snapshotFor(logicalId)?.networkSpeedMBps, 0);
    expect(manager.snapshotFor(logicalId)?.timeRemaining, Duration.zero);
  });

  test('parallel pause waits for every child pause observation', () async {
    final readiness = NativeParallelPauseReadinessV2();
    final f = _fixture(parallelChunks: 2, pauseReadiness: readiness);
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;

    var completed = false;
    final pauseFuture = f.manager.pause(f.request.logicalId).whenComplete(() {
      completed = true;
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.paused,
      reason: 'pause intent must be durable before native pause settles',
    );
    expect(completed, isFalse);
    expect(
      f.manager.snapshotFor(f.request.logicalId)?.status,
      DownloadTransportStatus.running,
    );

    readiness.observe(
      parentTaskId: taskId,
      childTaskId: 'child-1',
      statusOrdinal: TaskStatus.paused.index,
    );
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    readiness.observe(
      parentTaskId: taskId,
      childTaskId: 'child-2',
      statusOrdinal: TaskStatus.paused.index,
    );
    final paused = await pauseFuture;

    expect(completed, isTrue);
    expect(paused?.status, DownloadTransportStatus.paused);
    expect(
      f.manager.snapshotFor(f.request.logicalId)?.status,
      DownloadTransportStatus.paused,
    );
  });

  test('parallel resume reuses confirmed child pause observations', () async {
    final readiness = NativeParallelPauseReadinessV2();
    final f = _fixture(parallelChunks: 2, pauseReadiness: readiness);
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;

    final pauseFuture = f.manager.pause(f.request.logicalId);
    await Future<void>.delayed(Duration.zero);
    expect(handle.resumeCalls, 0);

    readiness.observe(
      parentTaskId: taskId,
      childTaskId: 'child-1',
      statusOrdinal: TaskStatus.paused.index,
    );
    readiness.observe(
      parentTaskId: taskId,
      childTaskId: 'child-2',
      statusOrdinal: TaskStatus.paused.index,
    );
    await pauseFuture;

    await f.manager.resume(f.request.logicalId);

    expect(handle.resumeCalls, 1);
    expect(f.gateway.startedSpecs, hasLength(1));
    expect((await f.store.get(f.request.logicalId))?.generation, 1);
    expect((await f.store.get(f.request.logicalId))?.taskId, taskId);
  });

  test('paused projection keeps progress-derived presentation bytes', () async {
    final f = _fixture(parallelChunks: 16);
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;
    handle.emitSnapshot(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: 0.25,
        transferredBytes: 0,
        totalBytes: 100,
      ),
    );
    handle.onPause = () async {
      handle.emitSnapshot(
        DownloadTransportSnapshot(
          taskId: taskId,
          status: DownloadTransportStatus.paused,
          progress: 0.25,
          transferredBytes: 0,
          totalBytes: 100,
        ),
      );
      return true;
    };

    final paused = await f.manager.pause(f.request.logicalId);

    expect(paused?.progress, 0.25);
    expect(
      paused?.transferredBytes,
      25,
      reason:
          'pause/status projection must not publish 25% progress with zero '
          'presentation bytes',
    );
  });

  test(
    'pause waits for package paused state before allowing exact resume',
    () async {
      final f = _fixture();
      await f.manager.start(f.request);
      final taskId = f.gateway.startedSpecs.single.taskId;
      final handle = f.gateway.handleFor(taskId)!;
      handle.onPause = () async => true;

      var pauseCompleted = false;
      final pauseFuture = f.manager.pause(f.request.logicalId).whenComplete(() {
        pauseCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);

      expect(pauseCompleted, isFalse);
      expect(handle.pauseCalls, 1);

      f.gateway.emit(taskId, DownloadTransportStatus.paused);
      final paused = await pauseFuture;
      expect(paused?.status, DownloadTransportStatus.paused);

      final resumed = await f.manager.resume(f.request.logicalId);

      expect(resumed.taskId, taskId);
      expect(handle.resumeCalls, 1);
      expect(f.gateway.startedSpecs, hasLength(1));
      expect((await f.store.get(f.request.logicalId))?.generation, 1);
    },
  );

  test('pause intent is durable before package pause', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final handle = f.gateway.handleFor(f.gateway.startedSpecs.single.taskId)!;
    handle.onPause = () async {
      expect(
        (await f.store.get(f.request.logicalId))?.intent,
        DownloadUserIntent.paused,
      );
      handle.emit(DownloadTransportStatus.paused);
      return true;
    };

    await f.manager.pause(f.request.logicalId);

    expect(handle.pauseCalls, 1);
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.paused,
    );
  });

  test(
    'rejects a second logical writer for the same canonical destination',
    () async {
      final f = _fixture();
      final conflicting = DownloadStartRequestV2(
        logicalId: logicalDownloadIdFor(
          animeId: 'anilist:22',
          episodeKey: '13',
          variantKey: 'sub:1080p',
        ),
        mediaId: 'anilist:22',
        unitKey: '13',
        variantKey: 'sub:1080p',
        destinationPath: f.request.destinationPath,
        sourceDescriptor: const <String, Object?>{
          'providerId': 'provider.example',
        },
        allowPause: true,
        retries: 2,
        parallelChunks: 1,
      );

      await f.manager.start(f.request);

      await expectLater(f.manager.start(conflicting), throwsStateError);

      expect(f.gateway.startedSpecs, hasLength(1));
      expect(f.resolver.calls, 1);
    },
  );

  test(
    'resume refuses duplicate paused owners of one canonical destination',
    () async {
      final store = InMemoryLogicalDownloadStoreV2();
      final gateway = _FakeGateway();
      final resolver = StaticSourceResolverV2();
      const destination = 'downloads/anime/shared-episode.mp4';

      final firstId = logicalDownloadIdFor(
        animeId: 'anilist:21',
        episodeKey: '12',
        variantKey: 'sub:1080p',
      );
      final secondId = logicalDownloadIdFor(
        animeId: 'anilist:22',
        episodeKey: '13',
        variantKey: 'sub:1080p',
      );
      final firstTaskId = taskIdForGeneration(firstId, 1);
      final secondTaskId = taskIdForGeneration(secondId, 1);

      for (final record in <LogicalDownloadRecordV2>[
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: firstId,
          mediaId: 'anilist:21',
          unitKey: '12',
          variantKey: 'sub:1080p',
          generation: 1,
          taskId: firstTaskId,
          intent: DownloadUserIntent.paused,
          destinationPath: destination,
          sourceDescriptor: const <String, Object?>{
            'providerId': 'provider.example',
          },
          allowPause: true,
          retries: 2,
          parallelChunks: 1,
          updatedAtMillis: 1,
        ),
        LogicalDownloadRecordV2(
          schemaVersion: kLogicalDownloadSchemaVersionV2,
          logicalId: secondId,
          mediaId: 'anilist:22',
          unitKey: '13',
          variantKey: 'sub:1080p',
          generation: 1,
          taskId: secondTaskId,
          intent: DownloadUserIntent.paused,
          destinationPath: destination,
          sourceDescriptor: const <String, Object?>{
            'providerId': 'provider.example',
          },
          allowPause: true,
          retries: 2,
          parallelChunks: 1,
          updatedAtMillis: 2,
        ),
      ]) {
        await store.put(record);
        await gateway.start(
          DownloadTaskSpecV2(
            taskId: record.taskId,
            url: 'https://example.invalid/video.mp4',
            destinationPath: destination,
            headers: const <String, String>{},
            allowPause: true,
            retries: 2,
            parallelChunks: 1,
          ),
        );
        gateway.emit(record.taskId, DownloadTransportStatus.paused);
      }

      final manager = DownloadManagerV2(
        store: store,
        gateway: gateway,
        sourceResolver: resolver,
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await expectLater(manager.resume(firstId), throwsStateError);

      expect(gateway.handleFor(firstTaskId)!.resumeCalls, 0);
      expect(gateway.handleFor(secondTaskId)!.resumeCalls, 0);
      expect((await store.get(firstId))?.intent, DownloadUserIntent.paused);
      expect((await store.get(secondId))?.intent, DownloadUserIntent.paused);
    },
  );

  test(
    'resumable paused handle becomes durably active without replacement',
    () async {
      final f = _fixture();
      await f.manager.start(f.request);
      final taskId = f.gateway.startedSpecs.single.taskId;
      final handle = f.gateway.handleFor(taskId)!;

      await f.manager.pause(f.request.logicalId);
      f.gateway.emit(taskId, DownloadTransportStatus.paused);

      await f.manager.resume(f.request.logicalId);

      expect(handle.resumeCalls, 1);
      expect(f.gateway.startedSpecs, hasLength(1));
      expect(f.resolver.calls, 1);
      expect(
        (await f.store.get(f.request.logicalId))?.intent,
        DownloadUserIntent.active,
      );
      expect(f.manager.snapshotFor(f.request.logicalId)?.taskId, taskId);
    },
  );

  test(
    'failed exact resume keeps paused generation without replacement',
    () async {
      final f = _fixture();
      await f.manager.start(f.request);
      final firstTaskId = f.gateway.startedSpecs.single.taskId;
      final handle = f.gateway.handleFor(firstTaskId)!;

      await f.manager.pause(f.request.logicalId);
      f.gateway.emit(firstTaskId, DownloadTransportStatus.paused);
      handle.onResume = () async => false;

      await expectLater(
        f.manager.resume(f.request.logicalId),
        throwsStateError,
      );

      expect(handle.resumeCalls, 1);
      expect(handle.cancelCalls, 0);
      expect(f.gateway.startedSpecs, hasLength(1));
      expect((await f.store.get(f.request.logicalId))?.generation, 1);
      expect((await f.store.get(f.request.logicalId))?.taskId, firstTaskId);
      expect(
        (await f.store.get(f.request.logicalId))?.intent,
        DownloadUserIntent.paused,
      );
    },
  );
  test(
    'canceled exact handle after resume failure cannot restart generation',
    () async {
      final f = _fixture();
      await f.manager.start(f.request);
      final taskId = f.gateway.startedSpecs.single.taskId;
      final handle = f.gateway.handleFor(taskId)!;

      await f.manager.pause(f.request.logicalId);
      f.gateway.emit(taskId, DownloadTransportStatus.paused);
      handle.onResume = () async => false;

      await expectLater(
        f.manager.resume(f.request.logicalId),
        throwsStateError,
      );
      f.gateway.emit(taskId, DownloadTransportStatus.canceled);
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        f.manager.resume(f.request.logicalId),
        throwsStateError,
      );

      expect(f.gateway.startedSpecs, hasLength(1));
      expect((await f.store.get(f.request.logicalId))?.generation, 1);
      expect((await f.store.get(f.request.logicalId))?.taskId, taskId);
      expect(
        (await f.store.get(f.request.logicalId))?.intent,
        DownloadUserIntent.paused,
      );
    },
  );

  test('failed pause never cancels transport or publishes fake paused state', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    final handle = f.gateway.handleFor(taskId)!;
    handle.onPause = () async => false;

    await expectLater(f.manager.pause(f.request.logicalId), throwsStateError);

    expect(
      handle.cancelCalls,
      0,
      reason: 'a failed iOS pause must not destroy the exact resumable writer',
    );
    expect(
      f.manager.snapshotFor(f.request.logicalId)?.status,
      DownloadTransportStatus.running,
      reason:
          'V2 must never relabel a live/canceled transport as safely paused',
    );
    expect(
      (await f.store.get(f.request.logicalId))?.intent,
      DownloadUserIntent.active,
      reason:
          'a rejected pause must roll back paused intent while the writer '
          'remains active',
    );

    handle.emitSnapshot(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: 0.6,
        transferredBytes: 60,
        totalBytes: 100,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      f.manager.snapshotFor(f.request.logicalId)?.status,
      DownloadTransportStatus.running,
      reason:
          'later transport progress after a failed pause must not be relabeled '
          'as safely paused just because the durable user intent is paused',
    );
    expect(f.manager.snapshotFor(f.request.logicalId)?.progress, 0.6);
  });

  test(
    'missing paused V2 transport refuses implicit byte-zero restart',
    () async {
      final f = _fixture();
      await f.manager.start(f.request);
      final firstTaskId = f.gateway.startedSpecs.single.taskId;
      await f.manager.pause(f.request.logicalId);
      f.gateway.emit(firstTaskId, DownloadTransportStatus.missing);

      await expectLater(
        f.manager.resume(f.request.logicalId),
        throwsStateError,
      );

      expect(f.gateway.startedSpecs, hasLength(1));
      expect(f.resolver.calls, 1);
      expect((await f.store.get(f.request.logicalId))?.generation, 1);
      expect(
        (await f.store.get(f.request.logicalId))?.intent,
        DownloadUserIntent.paused,
      );
    },
  );

  test(
    'cancel waits for obsolete writer settlement before releasing tracking',
    () async {
      final f = _fixture();
      await f.manager.start(f.request);
      final taskId = f.gateway.startedSpecs.single.taskId;
      final handle = f.gateway.handleFor(taskId)!;
      final cancelEntered = Completer<void>();
      handle.onCancel = () async {
        cancelEntered.complete();
        return true;
      };

      var completed = false;
      final cancelFuture = f.manager.cancel(f.request.logicalId).whenComplete(
        () {
          completed = true;
        },
      );
      try {
        await cancelEntered.future.timeout(const Duration(seconds: 5));
        expect(handle.cancelCalls, 1);
        expect(completed, isFalse);
        expect(f.gateway.removedTracking, isNot(contains(taskId)));
      } finally {
        f.gateway.emit(taskId, DownloadTransportStatus.canceled);
        await cancelFuture;
      }

      expect(completed, isTrue);
      expect(f.gateway.removedTracking, contains(taskId));
      expect(
        (await f.store.get(f.request.logicalId))?.intent,
        DownloadUserIntent.canceled,
      );
    },
  );

  test('canceled intent fences the real generation before late callback', () async {
    final f = _fixture();
    await f.manager.start(f.request);
    final oldTaskId = f.gateway.startedSpecs.single.taskId;

    await f.manager.cancel(f.request.logicalId);
    final canceledRecord = await f.store.get(f.request.logicalId);
    expect(canceledRecord, isNotNull);
    expect(canceledRecord!.intent, DownloadUserIntent.canceled);
    expect(canceledRecord.taskId, oldTaskId);
    expect(canceledRecord.generation, 1);

    f.gateway.emit(oldTaskId, DownloadTransportStatus.complete);
    await Future<void>.delayed(Duration.zero);

    expect(
      f.manager.snapshotFor(f.request.logicalId)?.taskId,
      canceledRecord.taskId,
    );
    expect(
      f.manager.snapshotFor(f.request.logicalId)?.status,
      DownloadTransportStatus.canceled,
    );
  });

  test('delete is idempotent when destination is already missing', () async {
    final temp = await Directory.systemTemp.createTemp(
      'animewitcher-v2-delete-',
    );
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    final destination = File(
      '${temp.path}${Platform.pathSeparator}episode.mp4',
    );
    await destination.writeAsBytes(<int>[1, 2, 3]);
    final f = _fixture(destinationPath: destination.path);
    await f.manager.start(f.request);

    await f.manager.delete(f.request.logicalId);
    await f.manager.delete(f.request.logicalId);

    expect(await destination.exists(), isFalse);
    expect(await f.store.get(f.request.logicalId), isNull);
  });
}

_Fixture _fixture({
  String destinationPath = 'downloads/anime/episode-12.mp4',
  int parallelChunks = 1,
  NativeParallelPauseReadinessV2? pauseReadiness,
  List<DownloadPresentationObserverV2> presentationObservers = const [],
  DownloadDiagnosticsV2? diagnostics,
}) {
  final store = InMemoryLogicalDownloadStoreV2();
  final gateway = _FakeGateway();
  final resolver = StaticSourceResolverV2();
  final logicalId = logicalDownloadIdFor(
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
  );
  final request = DownloadStartRequestV2(
    logicalId: logicalId,
    mediaId: 'anilist:21',
    unitKey: '12',
    variantKey: 'sub:1080p',
    destinationPath: destinationPath,
    sourceDescriptor: const <String, Object?>{'providerId': 'provider.example'},
    allowPause: true,
    retries: 2,
    parallelChunks: parallelChunks,
  );
  return _Fixture(
    store: store,
    gateway: gateway,
    resolver: resolver,
    request: request,
    manager: DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
      parallelPauseReadiness: pauseReadiness,
      presentationObservers: presentationObservers,
      diagnostics: diagnostics,
    ),
  );
}

final class _Fixture {
  const _Fixture({
    required this.store,
    required this.gateway,
    required this.resolver,
    required this.request,
    required this.manager,
  });

  final InMemoryLogicalDownloadStoreV2 store;
  final _FakeGateway gateway;
  final StaticSourceResolverV2 resolver;
  final DownloadStartRequestV2 request;
  final DownloadManagerV2 manager;
}

final class _FakeGateway implements BackgroundDownloaderGateway {
  final List<DownloadTaskSpecV2> startedSpecs = <DownloadTaskSpecV2>[];
  final List<String> removedTracking = <String>[];
  final Map<String, _FakeHandle> _handles = <String, _FakeHandle>{};
  Future<void> Function(String taskId)? onRemoveTracking;

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    startedSpecs.add(spec);
    final handle = _FakeHandle(
      DownloadTransportSnapshot(
        taskId: spec.taskId,
        status: DownloadTransportStatus.running,
        progress: 0,
      ),
    );
    _handles[spec.taskId] = handle;
    return handle;
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async =>
      _handles[taskId];

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      _handles.values.toList(growable: false);

  @override
  Future<void> removeTracking(String taskId) async {
    await onRemoveTracking?.call(taskId);
    removedTracking.add(taskId);
  }

  _FakeHandle? handleFor(String taskId) => _handles[taskId];

  void emit(String taskId, DownloadTransportStatus status) {
    _handles[taskId]?.emit(status);
  }

  void emitSnapshot(String taskId, DownloadTransportSnapshot snapshot) {
    _handles[taskId]?.emitSnapshot(snapshot);
  }
}

final class _FakeHandle implements DownloadTransportHandle {
  _FakeHandle(this._current);

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);

  Future<bool> Function()? onPause;
  Future<bool> Function()? onResume;
  Future<bool> Function()? onCancel;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int cancelCalls = 0;

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  @override
  Future<bool> pause() async {
    pauseCalls++;
    final override = onPause;
    if (override != null) return override();
    emit(DownloadTransportStatus.paused);
    return true;
  }

  @override
  Future<bool> resume() async {
    resumeCalls++;
    return onResume?.call() ?? true;
  }

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    final override = onCancel;
    if (override != null) return override();
    emit(DownloadTransportStatus.canceled);
    return true;
  }

  void emit(DownloadTransportStatus status) {
    emitSnapshot(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: status,
        progress: status == DownloadTransportStatus.complete ? 1 : 0.5,
      ),
    );
  }

  void emitSnapshot(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    _controller.add(_current);
  }
}

final class _RecordingPresentationObserver
    implements DownloadPresentationObserverV2 {
  final List<(LogicalDownloadRecordV2, DownloadTransportSnapshot)> events =
      <(LogicalDownloadRecordV2, DownloadTransportSnapshot)>[];

  @override
  Future<void> observe(
    LogicalDownloadRecordV2 record,
    DownloadTransportSnapshot snapshot,
  ) async {
    events.add((record, snapshot));
  }

  @override
  Future<void> dispose() async {}
}
