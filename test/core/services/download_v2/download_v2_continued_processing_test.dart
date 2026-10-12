import 'dart:async';

import '../../../support/widget_completion.dart';

import 'package:animewitcher/core/services/download_continued_processing_service.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:animewitcher/core/services/download_v2/download_continued_processing_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'com.animewitcher.app/download_continued_processing',
  );

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('successful terminal observer flushes final progress before native finish inside the sample window', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final service = DownloadContinuedProcessingService(onSystemCancel: (_) async {}, forceAvailableForTesting: true);
    final observer = IosDownloadContinuedProcessingObserverV2(service: service);
    try {
      final record = _terminalProgressRecord();
      await observer.observe(record, DownloadTransportSnapshot(
        taskId: record.taskId, status: DownloadTransportStatus.running,
        progress: .25, transferredBytes: 250, totalBytes: 1000,
      ));
      await observer.observe(record.copyWith(completedAtMillis: 1), DownloadTransportSnapshot(
        taskId: record.taskId, status: DownloadTransportStatus.complete,
        progress: 1, transferredBytes: 1000, totalBytes: 1000,
      ));
      expect(calls.map((call) => call.method), ['start', 'update', 'finish']);
      final finalUpdate = calls.singleWhere((call) => call.method == 'update').arguments as Map;
      expect(finalUpdate['taskId'], record.taskId);
      expect(finalUpdate['progress'], 1.0);
      expect(finalUpdate['totalBytes'], 1000);
      expect(finalUpdate['transferredBytes'], 1000);
      expect(finalUpdate['completedCount'], 0);
      expect(finalUpdate['batchTotal'], 1);
      expect(finalUpdate['currentIndex'], 1);
      await tester.pump(const Duration(seconds: 2));
      expect(calls.map((call) => call.method), ['start', 'update', 'finish']);
    } finally {
      await observer.dispose();
    }
  });

  testWidgets('successful finish awaits a timer-fired update then final pending data in order', (tester) async {
    final calls = <MethodCall>[];
    final started = Completer<void>();
    final release = Completer<void>();
    var updates = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'update' && ++updates == 1) {
        started.complete();
        await release.future;
      }
      return true;
    });
    final service = DownloadContinuedProcessingService(onSystemCancel: (_) async {}, forceAvailableForTesting: true);
    Future<void>? finish;
    try {
      await service.start(taskId: 'terminal-task', displayName: 'Saved episode');
      await service.update(taskId: 'terminal-task', progress: .25, totalBytes: 1000, transferredBytes: 250);
      await tester.pump(const Duration(milliseconds: 1100));
      await pumpUntilFuture(tester, started.future, 'timer-fired native update entry');
      await service.update(taskId: 'terminal-task', progress: 1, totalBytes: 1000, transferredBytes: 1000);
      finish = service.finish(taskId: 'terminal-task', success: true, status: 'completed', endSession: true);
      await tester.pump();
      expect(calls.where((call) => call.method == 'finish'), isEmpty,
        reason: 'finish must not overtake the already-issued update');
    } finally {
      release.complete();
      if (finish != null) await pumpUntilFuture(tester, finish, 'ordered native terminal finish');
      await service.dispose();
    }
    expect(calls.map((call) => call.method), ['start', 'update', 'update', 'finish']);
    final finalUpdate = calls.where((call) => call.method == 'update').last.arguments as Map;
    expect(finalUpdate['progress'], 1.0);
    expect(finalUpdate['transferredBytes'], 1000);
  });

  for (final terminal in ['failed', 'stop', 'dispose']) {
    testWidgets('$terminal discards throttled progress without a late native update', (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      final service = DownloadContinuedProcessingService(onSystemCancel: (_) async {}, forceAvailableForTesting: true);
      try {
        await service.start(taskId: 'discard-task', displayName: 'Saved');
        await service.update(taskId: 'discard-task', progress: .4, totalBytes: 1000);
        if (terminal == 'failed') {
          await service.finish(taskId: 'discard-task', success: false, status: 'failed', endSession: true);
        } else if (terminal == 'stop') {
          await service.stop(taskId: 'discard-task', endSession: true);
        } else {
          await service.dispose();
        }
        await tester.pump(const Duration(seconds: 2));
        expect(calls.where((call) => call.method == 'update'), isEmpty);
      } finally {
        await service.dispose();
      }
    });
  }

  testWidgets('stale successful finish never flushes another task pending data', (tester) async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final service = DownloadContinuedProcessingService(onSystemCancel: (_) async {}, forceAvailableForTesting: true);
    try {
      await service.start(taskId: 'previous-task', displayName: 'Previous');
      await service.start(taskId: 'current-task', displayName: 'Current');
      await service.update(taskId: 'current-task', progress: 1, totalBytes: 1000, transferredBytes: 1000);
      await service.finish(taskId: 'previous-task', success: true, status: 'completed', endSession: true);
      expect(calls.where((call) => call.method == 'update'), isEmpty);
    } finally {
      await service.dispose();
    }
  });

  test('parallel native speed sums live child windows without zero spikes', () {
    final speeds = NativeParallelSpeedAccumulatorV2();

    expect(
      speeds.update(
        parentTaskId: 'aw_v2_dl_x_g1',
        childTaskId: 'child-1',
        speedBytesPerSecond: 4_000_000,
        completed: false,
      ),
      4_000_000,
    );
    expect(
      speeds.update(
        parentTaskId: 'aw_v2_dl_x_g1',
        childTaskId: 'child-2',
        speedBytesPerSecond: 6_000_000,
        completed: false,
      ),
      10_000_000,
    );

    // A throttled callback without a stable speed sample must not turn a live
    // transfer into a fake 0 MB/s reading.
    expect(
      speeds.update(
        parentTaskId: 'aw_v2_dl_x_g1',
        childTaskId: 'child-2',
        speedBytesPerSecond: null,
        completed: false,
      ),
      10_000_000,
    );

    // An explicit zero is different: native emits it only after the child has
    // produced no bytes for the stale window, so remove that child speed.
    expect(
      speeds.update(
        parentTaskId: 'aw_v2_dl_x_g1',
        childTaskId: 'child-1',
        speedBytesPerSecond: 0,
        completed: false,
      ),
      6_000_000,
    );

    expect(
      speeds.update(
        parentTaskId: 'aw_v2_dl_x_g1',
        childTaskId: 'child-2',
        completed: true,
      ),
      isNull,
      reason:
          'finishing the last immutable range is a handoff, not proof that '
          'the parent network speed became zero',
    );

    expect(
      speeds.update(
        parentTaskId: 'aw_v2_dl_y_g1',
        childTaskId: 'child',
        speedBytesPerSecond: 1_000_000,
        completed: false,
      ),
      1_000_000,
    );
    expect(
      speeds.update(
        parentTaskId: 'aw_v2_dl_y_g1',
        childTaskId: 'child',
        speedBytesPerSecond: 0,
        completed: false,
      ),
      0,
      reason: 'an explicit stale zero from a still-owned child remains real',
    );
    expect(
      speeds.update(
        parentTaskId: 'legacy-parent',
        childTaskId: 'child',
        speedBytesPerSecond: 99_000_000,
        completed: false,
      ),
      isNull,
    );
  });

  test(
    'parallel resume readiness accepts paused or already-complete children',
    () async {
      final readiness = NativeParallelPauseReadinessV2();
      var completed = false;

      final readyFuture = readiness
          .waitUntilReady(
            taskId: 'aw_v2_parent_g1',
            expectedChildren: 2,
            timeout: const Duration(seconds: 1),
          )
          .whenComplete(() {
            completed = true;
          });

      readiness.observe(
        parentTaskId: 'aw_v2_parent_g1',
        childTaskId: 'child-1',
        statusOrdinal: TaskStatus.paused.index,
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      readiness.observe(
        parentTaskId: 'aw_v2_parent_g1',
        childTaskId: 'child-2',
        statusOrdinal: TaskStatus.complete.index,
      );

      expect(await readyFuture, isTrue);
      expect(completed, isTrue);
    },
  );


  test('a lost iOS system lease restarts for the same running generation', () async {
    final calls = <MethodCall>[];
    var allowUpdate = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'start') {
            return 'com.animewitcher.app.download.session';
          }
          if (call.method == 'update') return allowUpdate;
          return true;
        });
    final service = DownloadContinuedProcessingService(
      onSystemCancel: (_) async {},
      forceAvailableForTesting: true,
    );
    final observer = IosDownloadContinuedProcessingObserverV2(service: service);
    final record = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: const DownloadLogicalId('recovered-episode'),
      mediaId: 'anime-1',
      unitKey: 'episode-1',
      variantKey: 'sub|480p',
      generation: 2,
      taskId: 'aw_v2_recovered_episode_g2',
      intent: DownloadUserIntent.active,
      destinationPath: 'downloads/Episode 1.mp4',
      sourceDescriptor: const <String, Object?>{'providerId': 'provider'},
      expectedBytes: 1000,
      updatedAtMillis: 1,
    );
    try {
      await observer.observe(
        record,
        const DownloadTransportSnapshot(
          taskId: 'aw_v2_recovered_episode_g2',
          status: DownloadTransportStatus.running,
          progress: .25,
          transferredBytes: 250,
          totalBytes: 1000,
        ),
      );
      expect(calls.where((c) => c.method == 'start'), hasLength(1));
      await observer.observe(
        record,
        const DownloadTransportSnapshot(
          taskId: 'aw_v2_recovered_episode_g2',
          status: DownloadTransportStatus.running,
          progress: .35,
          transferredBytes: 350,
          totalBytes: 1000,
        ),
      );
      // Swift reports false after the OS task expires while the native
      // URLSession writer continues. No manual pause/resume is required.
      for (var i = 0; i < 180 &&
          calls.where((c) => c.method == 'start').length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(calls.where((c) => c.method == 'update'), isNotEmpty,
          reason: 'the native update must have actually rejected the lease');
      expect(calls.where((c) => c.method == 'start'), hasLength(2));
      expect(calls.where((c) => c.method == 'stop'), isEmpty);
      allowUpdate = true;
    } finally {
      await observer.dispose();
    }
  });

  test(
    'package-owned queued V2 starts iOS session before first progress',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'start') {
              return 'com.animewitcher.app.download.session';
            }
            return true;
          });

      final service = DownloadContinuedProcessingService(
        onSystemCancel: (_) async {},
        forceAvailableForTesting: true,
      );
      final observer = IosDownloadContinuedProcessingObserverV2(
        service: service,
      );
      final record = LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: const DownloadLogicalId('episode-queued'),
        mediaId: 'anime-1',
        unitKey: 'queued',
        variantKey: 'sub|1080p',
        generation: 1,
        taskId: 'aw_v2_episode_queued_g1',
        intent: DownloadUserIntent.active,
        destinationPath: 'downloads/Queued/Episode.mp4',
        sourceDescriptor: const <String, Object?>{'providerId': 'provider'},
        expectedBytes: 400,
        updatedAtMillis: 1,
      );

      try {
        await observer.observe(
          record,
          const DownloadTransportSnapshot(
            taskId: 'aw_v2_episode_queued_g1',
            status: DownloadTransportStatus.queued,
            progress: 0,
            transferredBytes: 0,
            totalBytes: 400,
          ),
        );

        final start = calls.singleWhere((call) => call.method == 'start');
        final args = Map<String, Object?>.from(start.arguments as Map);
        expect(args['progress'], 0.0);
        expect(args['totalBytes'], 400);
        expect(args['transferredBytes'], 0);
      } finally {
        await observer.dispose();
      }
    },
  );

  test(
    'admission-only queued V2 does not claim iOS continued processing',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'start') {
              return 'com.animewitcher.app.download.session';
            }
            return true;
          });

      final service = DownloadContinuedProcessingService(
        onSystemCancel: (_) async {},
        forceAvailableForTesting: true,
      );
      final observer = IosDownloadContinuedProcessingObserverV2(
        service: service,
      );
      final record = LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: const DownloadLogicalId('episode-waiting'),
        mediaId: 'anime-1',
        unitKey: 'waiting',
        variantKey: 'sub|1080p',
        generation: 1,
        taskId: 'aw_v2_episode_waiting_g1',
        intent: DownloadUserIntent.active,
        destinationPath: 'downloads/Waiting/Episode.mp4',
        sourceDescriptor: const <String, Object?>{'providerId': 'provider'},
        expectedBytes: 400,
        awaitingAdmission: true,
        updatedAtMillis: 1,
      );

      try {
        await observer.observe(
          record,
          const DownloadTransportSnapshot(
            taskId: 'aw_v2_episode_waiting_g1',
            status: DownloadTransportStatus.queued,
            progress: 0,
            transferredBytes: 0,
            totalBytes: 400,
          ),
        );

        expect(calls.where((call) => call.method == 'start'), isEmpty);
      } finally {
        await observer.dispose();
      }
    },
  );

  test(
    'historical completion does not join a new iOS download session',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'start') {
              return 'com.animewitcher.app.download.session';
            }
            return true;
          });

      final service = DownloadContinuedProcessingService(
        onSystemCancel: (_) async {},
        forceAvailableForTesting: true,
      );
      final observer = IosDownloadContinuedProcessingObserverV2(
        service: service,
      );
      final oldRecord = LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: const DownloadLogicalId('episode-old'),
        mediaId: 'anime-1',
        unitKey: 'old',
        variantKey: 'sub|1080p',
        generation: 1,
        taskId: 'aw_v2_episode_old_g1',
        intent: DownloadUserIntent.active,
        destinationPath: 'downloads/Old/Episode.mp4',
        sourceDescriptor: const <String, Object?>{'providerId': 'provider'},
        expectedBytes: 400,
        completedAtMillis: 1,
        updatedAtMillis: 1,
      );
      final currentRecord = LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: const DownloadLogicalId('episode-current'),
        mediaId: 'anime-1',
        unitKey: 'current',
        variantKey: 'sub|1080p',
        generation: 1,
        taskId: 'aw_v2_episode_current_g1',
        intent: DownloadUserIntent.active,
        destinationPath: 'downloads/Current/Episode.mp4',
        sourceDescriptor: const <String, Object?>{'providerId': 'provider'},
        expectedBytes: 400,
        updatedAtMillis: 2,
      );

      try {
        await observer.observe(
          oldRecord,
          const DownloadTransportSnapshot(
            taskId: 'aw_v2_episode_old_g1',
            status: DownloadTransportStatus.complete,
            progress: 1,
            transferredBytes: 400,
            totalBytes: 400,
          ),
        );
        await observer.observe(
          currentRecord,
          const DownloadTransportSnapshot(
            taskId: 'aw_v2_episode_current_g1',
            status: DownloadTransportStatus.running,
            progress: 0.25,
            transferredBytes: 100,
            totalBytes: 400,
            networkSpeedMBps: 2,
          ),
        );

        final start = calls.singleWhere((call) => call.method == 'start');
        final args = Map<String, Object?>.from(start.arguments as Map);
        expect(args['batchTotal'], 1);
        expect(args['completedCount'], 0);
        expect(args['currentIndex'], 1);
      } finally {
        await observer.dispose();
      }
    },
  );

  test(
    'V2 checkpoints native range refill before Flutter can suspend',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'start') {
              return 'com.animewitcher.app.download.session';
            }
            if (call.method == 'persistNativeQueue') {
              final args = Map<Object?, Object?>.from(call.arguments as Map);
              return <String, Object>{
                'acceptedVersion': args['snapshotVersion']! as int,
                'nativePromotionAvailable': true,
              };
            }
            return true;
          });

      final service = DownloadContinuedProcessingService(
        onSystemCancel: (_) async {},
        forceAvailableForTesting: true,
      );
      final observer = IosDownloadContinuedProcessingObserverV2(
        service: service,
        nativeBackgroundPlans: () => <Map<String, Object>>[
          <String, Object>{
            'parentTaskId': 'aw_v2_episode_11_g1',
            'maxConcurrent': 1,
            'waiters': <Map<String, Object>>[
              <String, Object>{
                'taskId': 'aw_v2_episode_11_g1.part.8',
                'taskJson': '{"taskId":"aw_v2_episode_11_g1.part.8"}',
                'url': 'https://example.invalid/video.mp4',
                'filename': '8.part',
                'headers': <String, String>{'Range': 'bytes=800-899'},
                'directory': 'downloads/.parts',
                'httpRequestMethod': 'GET',
                'group': 'animewitcher_parts',
                'generation': 1,
                'claimId': 'claim-8',
                'claimLeaseMillis': 900000,
              },
            ],
          },
        ],
      );
      final record = LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: const DownloadLogicalId('episode-11'),
        mediaId: 'anime-1',
        unitKey: '11',
        variantKey: 'sub|1080p',
        generation: 1,
        taskId: 'aw_v2_episode_11_g1',
        intent: DownloadUserIntent.active,
        destinationPath: 'downloads/Yani Neko/Episode 11.mp4',
        sourceDescriptor: const <String, Object?>{'providerId': 'provider'},
        expectedBytes: 400,
        updatedAtMillis: 1,
      );

      try {
        await observer.observe(
          record,
          const DownloadTransportSnapshot(
            taskId: 'aw_v2_episode_11_g1',
            status: DownloadTransportStatus.running,
            progress: 0.25,
            transferredBytes: 100,
            totalBytes: 400,
            networkSpeedMBps: 2.5,
            timeRemaining: Duration(seconds: 30),
          ),
        );

        final start = calls.singleWhere((call) => call.method == 'start');
        final args = Map<String, Object?>.from(start.arguments as Map);
        expect(args['displayName'], 'Episode 11');
        expect(args['progress'], 0.25);
        expect(args['transferredBytes'], 100);
        expect(args['totalBytes'], 400);
        expect(args['speedBytesPerSecond'], 2500000.0);

        final checkpoint = calls.singleWhere(
          (call) => call.method == 'persistNativeQueue',
        );
        final checkpointArgs = Map<Object?, Object?>.from(
          checkpoint.arguments as Map,
        );
        expect(checkpointArgs['transferringTaskIds'], <String>[
          'aw_v2_episode_11_g1',
        ]);
        final plans = checkpointArgs['multipartPlans']! as List;
        expect(plans, hasLength(1));
        final plan = Map<Object?, Object?>.from(plans.single as Map);
        expect(plan['parentTaskId'], 'aw_v2_episode_11_g1');
        expect(plan['maxConcurrent'], 1);
        expect((plan['waiters']! as List), hasLength(1));

        await observer.observe(
          record,
          const DownloadTransportSnapshot(
            taskId: 'aw_v2_episode_11_g1',
            status: DownloadTransportStatus.paused,
            progress: 0.25,
            transferredBytes: 100,
            totalBytes: 400,
          ),
        );

        final stop = calls.lastWhere((call) => call.method == 'stop');
        final stopArgs = Map<String, Object?>.from(stop.arguments as Map);
        expect(stopArgs['endSession'], isTrue);
        final checkpoints = calls
            .where((call) => call.method == 'persistNativeQueue')
            .toList(growable: false);
        expect(checkpoints, hasLength(2));
        final cleared = Map<Object?, Object?>.from(
          checkpoints.last.arguments as Map,
        );
        expect(cleared['multipartPlans'], isEmpty);
        expect(cleared['pausedTaskIds'], <String>['aw_v2_episode_11_g1']);
      } finally {
        await observer.dispose();
      }
    },
  );
}
LogicalDownloadRecordV2 _terminalProgressRecord() => const LogicalDownloadRecordV2(
  schemaVersion: kLogicalDownloadSchemaVersionV2, logicalId: DownloadLogicalId('terminal-progress'),
  mediaId: 'saved-show', unitKey: 'saved-episode', variantKey: 'original', generation: 1,
  taskId: 'aw_v2_terminal_progress_g1', intent: DownloadUserIntent.active,
  destinationPath: 'downloads/saved.mp4', sourceDescriptor: {}, expectedBytes: 1000, updatedAtMillis: 1,
);
