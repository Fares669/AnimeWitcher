import 'dart:io';

import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('runtime download stability review', () {
    test('sub-second callback bursts are not reported as download speed', () {
      final estimator = DownloadTelemetryEstimator();
      final start = DateTime(2026, 9, 9, 12);
      estimator.observe(
        taskId: 'episode',
        transferredBytes: 0,
        expectedBytes: 20 * 1000 * 1000,
        now: start,
      );
      final burst = estimator.observe(
        taskId: 'episode',
        transferredBytes: 2 * 1000 * 1000,
        expectedBytes: 20 * 1000 * 1000,
        now: start.add(const Duration(milliseconds: 200)),
      );
      expect(burst.speedBytesPerSecond, 0);

      final stable = estimator.observe(
        taskId: 'episode',
        transferredBytes: 4 * 1000 * 1000,
        expectedBytes: 20 * 1000 * 1000,
        now: start.add(const Duration(seconds: 2)),
      );
      expect(stable.speedBytesPerSecond, closeTo(2 * 1000 * 1000, 1));
    });

    test('engine ownership keeps a session alive through a DB/UI gap', () {
      expect(
        downloadSessionHasRemainingWork(
          runningCount: 0,
          waitingCount: 0,
          activeEngineCount: 1,
        ),
        isTrue,
      );
      expect(
        downloadSessionHasRemainingWork(
          runningCount: 0,
          waitingCount: 0,
          activeEngineCount: 0,
        ),
        isFalse,
      );
    });

    test('iOS system task uses rolling speed and does not finish on a gap', () {
      final swift = File('ios/Runner/DownloadNativeWaitingQueue.swift')
          .readAsStringSync();
      expect(swift, contains('speedWindowInterval: CFTimeInterval = 4.0'));
      expect(swift, contains('chunkBridgeInterval: CFTimeInterval = 1.0'));
      expect(swift, contains('taskBridgeInterval: CFTimeInterval = 1.0'));
      expect(swift, contains('if bridgedToDart && !isAppInForeground()'));
      expect(swift, contains('elapsed >= speedMinimumWindow'));
      expect(swift, contains('speedStaleInterval: CFTimeInterval = 3.0'));
      expect(swift, contains('let hasKnownOutstandingEpisode'));
      expect(swift, contains('let batchStillOutstanding'));
      expect(swift, isNot(contains('lastWrites: [String: WriteSample]')));
    });

    test('multipart coordinator errors recover instead of pausing parent', () {
      final source = File('lib/core/services/persistent_parallel_download.dart')
          .readAsStringSync();
      expect(source, contains('void _scheduleCoordinatorRecovery'));
      expect(
        source,
        contains('Coordinator bookkeeping is not a user-visible pause.'),
      );
      expect(source, contains('DownloadTelemetryEstimator _speedTelemetry'));
      expect(
        source,
        contains('kParallelProgressCoalesceDelay = Duration(seconds: 1)'),
      );
      expect(source, contains('kParallelProgressPersistInterval'));
      expect(source, contains('final nativeBridgeFresh ='));
      expect(source, contains('_scheduleProgressPersist(session)'));
    });

    test('multipart parent presentation clock is not serialized behind IO', () {
      final source = File('lib/core/services/persistent_parallel_download.dart')
          .readAsStringSync();
      final start = source.indexOf('void _scheduleAggregateProgress(');
      final end = source.indexOf('Duration _aggregateTimeRemaining', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final section = source.substring(start, end);
      expect(section, isNot(contains('session.serialize(')));
      expect(section, contains('void _emitAggregateProgress('));
      expect(section, contains('_writeParentRecord('));
    });

    test('multipart card uses coordinator speed as the canonical speed', () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      expect(
        source,
        contains(
          'final isAggregateMultipart = update.task is ParallelDownloadTask;',
        ),
      );
      expect(source, contains('final measuredSpeed = isAggregateMultipart'));
      expect(source, contains('? update.networkSpeed'));
    });

    test('iOS multipart pause preserves live URLSession range bytes', () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      expect(source, contains('preserveLiveParts: Platform.isIOS'));
      expect(source, contains('shouldDrainPartOnPause: (task) =>'));
      expect(
        source,
        contains("diagnosticLog.record('parallel.pauseDrainQueueRelease'"),
      );
      expect(
        source,
        contains(
          'if (_parallel.hasLiveConnections(taskId)) occupying.add(taskId);',
        ),
      );
      expect(
        source,
        contains(
          'final parentUserPaused = _userPausedIds.contains(parentTaskId);',
        ),
      );
      expect(source, contains('if (!parentUserPaused || completed)'));
    });

    test(
      'lost multipart resume checkpoint is repaired instead of retried forever',
      () {
        final source = File('lib/core/services/download_service.dart')
            .readAsStringSync();
        final start = source.indexOf('Future<bool> _startPart(');
        final end = source.indexOf('Future<bool> _enqueueTransfer(', start);
        expect(start, greaterThanOrEqualTo(0));
        expect(end, greaterThan(start));
        final section = source.substring(start, end);
        expect(section, contains("part.checkpointLost"));
        expect(section, contains('resetUndurablePartProgress('));
        expect(
          section,
          contains('final enqueued = await FileDownloader().enqueue(task);'),
        );
        expect(section, contains('return enqueued;'));
        expect(section, contains('forceSourceValidation'));
        expect(
          section,
          isNot(contains('if (progress > 0 || bytes > 0) return false;')),
        );
      },
    );

    test(
      'multipart manifests persist generation, byte and resource identity',
      () {
        final source = File(
          'lib/core/services/persistent_parallel_download.dart',
        ).readAsStringSync();
        expect(source, contains('kParallelManifestSchemaVersion = 5'));
        expect(
          source,
          contains("'schemaVersion': kParallelManifestSchemaVersion"),
        );
        expect(source, contains("'generation': session.generation"));
        expect(source, contains("'expectedBytes': session.size"));
        expect(
          source,
          contains("'resourceValidator': session.resourceValidator"),
        );
        expect(source, contains('generation: savedGeneration'));
        expect(
          source,
          contains(
            "final savedValidator = json['resourceValidator'] is String",
          ),
        );
        expect(
          source,
          contains(
            'resourceValidator: savedValidator.isEmpty ? null : savedValidator',
          ),
        );
        expect(source, contains('if (!contiguous) continue;'));
      },
    );

    test('complete assembly staging file is adopted after a crash', () {
      final source = File('lib/core/services/persistent_parallel_download.dart')
          .readAsStringSync();
      final start = source.indexOf('Future<bool> _adoptCompletedTarget(');
      final end = source.indexOf('bool _requestedByteRange(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final section = source.substring(start, end);
      expect(section, contains(".assembling"));
      expect(section, contains('await staging.rename(target.path)'));
      expect(section, contains('await file.length() != part.size'));
    });

    test('continued-processing speed zero explicitly clears stale speed', () {
      final swift = File('ios/Runner/DownloadContinuedProcessingManager.swift')
          .readAsStringSync();
      expect(swift, contains('speedBytesPerSecond >= 0'));
    });

    test(
      'multipart progress callback cannot feed native ingress back into itself',
      () {
        final source = File('lib/core/services/download_service.dart')
            .readAsStringSync();
        final start = source.indexOf(
          'onPartProgress: (parent, child, progress) {',
        );
        final end = source.indexOf('onHostPressure:', start);
        expect(start, greaterThanOrEqualTo(0));
        expect(end, greaterThan(start));
        final callback = source.substring(start, end);
        expect(callback, contains('_publishChunkProgress('));
        expect(callback, isNot(contains('_handleNativeChunkUpdate(')));
        expect(source, contains('void _publishChunkProgress({'));
      },
    );

    test(
      'continued-processing metric updates are coalesced to one per second',
      () {
        final source = File(
          'lib/core/services/download_continued_processing_service.dart',
        ).readAsStringSync();
        expect(
          source,
          contains('_updateSampleInterval = Duration(seconds: 1)'),
        );
        expect(source, contains('Future<void> _queueUpdate('));
        expect(source, contains('_pendingUpdate = arguments'));
        expect(source, contains('_cancelPendingUpdate();'));
      },
    );

    test(
      'startup reconciliation reads JobStore before legacy cancel filtering',
      () {
        final source = File('lib/core/services/download_service.dart')
            .readAsStringSync();
        final start = source.indexOf(
          'Future<void> _recoverPersistedDownloads()',
        );
        final end = source.indexOf('int _occupiedSlotCount(', start);
        expect(start, greaterThanOrEqualTo(0));
        expect(end, greaterThan(start));
        final recovery = source.substring(start, end);
        final jobRead = recovery.indexOf(
          'final oldJob = await _jobStore.get(task.taskId);',
        );
        final canceledFilter = recovery.indexOf(
          'record.status == TaskStatus.canceled',
        );
        expect(jobRead, greaterThanOrEqualTo(0));
        expect(canceledFilter, greaterThan(jobRead));
        expect(recovery, contains('planDownloadRecoveryWithJobAuthority('));
        expect(recovery, contains('oldJob?.expectedBytes'));
        expect(recovery, contains('oldJob?.userPaused == true'));
      },
    );

    test(
      'logical lifecycle boundaries checkpoint authoritative JobStore state',
      () {
        final source = File('lib/core/services/download_service.dart')
            .readAsStringSync();
        expect(source, contains('Future<bool> _checkpointLogicalJob('));
        expect(source, contains('state: DownloadJobState.pausing'));
        expect(source, contains('state: DownloadJobState.pausedByUser'));
        expect(source, contains('state: DownloadJobState.starting'));
        expect(source, contains('state: DownloadJobState.queued'));
        expect(source, contains('state: DownloadJobState.interrupted'));
        expect(source, contains('state: DownloadJobState.completed'));
        expect(source, contains('await _jobStore.remove(task.taskId);'));
      },
    );

    test(
      'iOS background transport failures retry before plugin Task failed',
      () {
        final swift = File('ios/Runner/DownloadNativeWaitingQueue.swift')
            .readAsStringSync();
        final hookStart = swift.indexOf('private static func hookComplete(');
        final hookEnd = swift.indexOf(
          'private static func hookFinishDownload(',
          hookStart,
        );
        expect(hookStart, greaterThanOrEqualTo(0));
        expect(hookEnd, greaterThan(hookStart));
        final hook = swift.substring(hookStart, hookEnd);
        expect(hook, contains('retryBackgroundTransferIfNeeded('));
        expect(hook, contains('return'));
        final retryIndex = hook.indexOf('retryBackgroundTransferIfNeeded(');
        final pluginCallbackIndex = hook.indexOf(
          'if let original = DownloadUrlSessionHook.originalComplete',
        );
        expect(retryIndex, greaterThanOrEqualTo(0));
        expect(pluginCallbackIndex, greaterThanOrEqualTo(0));
        expect(retryIndex, lessThan(pluginCallbackIndex));
        expect(swift, contains('background.retry.resumeData'));
        expect(swift, contains('background.retry.rangeRestart'));
        expect(swift, contains('replacement.earliestBeginDate'));
        expect(swift, contains('-1005, // network connection lost'));
        expect(swift, contains('-1009, // not connected to Internet'));
        expect(swift, isNot(contains('-999,  //')));

        final service = File('lib/core/services/download_service.dart')
            .readAsStringSync();
        expect(service, contains('Platform.isIOS'));
        expect(service, contains('const Duration(minutes: 10)'));
      },
    );

    test('pause intent fences a queued multipart slow-start pump', () {
      final source = File('lib/core/services/persistent_parallel_download.dart')
          .readAsStringSync();
      expect(source, contains('session.pauseRequested = true;'));
      expect(source, contains('session.pauseRequested = false;'));
      expect(source, contains('session.pauseRequested ||'));
      expect(source, contains('!session.pauseRequested &&'));
    });

    test('single-episode iOS overlay cannot multiply the file total', () {
      final swift = File('ios/Runner/DownloadNativeWaitingQueue.swift')
          .readAsStringSync();
      expect(swift, contains('if state.sessionBatchTotal <= 1'));
      expect(swift, contains('retainedNativeOwners + dartTransferring'));
      expect(
        swift,
        isNot(contains('current.transferringTaskIds + dartTransferring')),
      );
      expect(swift, contains('acceptsDartOverlayUpdates()'));

      final appDelegate = File('ios/Runner/AppDelegate.swift')
          .readAsStringSync();
      expect(
        appDelegate,
        contains('if !DownloadNativeWaitingQueue.acceptsDartOverlayUpdates()'),
      );
    });

    test(
      'iOS background multipart refills the proven connection width natively',
      () {
        final parallel = File(
          'lib/core/services/persistent_parallel_download.dart',
        ).readAsStringSync();
        expect(parallel, contains('nativeBackgroundPlans()'));
        expect(parallel, contains('maxConcurrent: provenWidth.clamp('));
        expect(parallel, contains('part.progress <= 0'));
        expect(parallel, contains('!part.sourceValidationRequired'));
        expect(
          parallel,
          contains('attemptGeneration == part.attemptGeneration'),
        );

        final swift = File('ios/Runner/DownloadNativeWaitingQueue.swift')
            .readAsStringSync();
        expect(swift, contains('struct MultipartPlan: Codable'));
        expect(swift, contains('promoteMultipartIfPossible('));
        expect(swift, contains('session.getAllTasks'));
        expect(swift, contains('startMultipartChild(waiter, on: session)'));
        expect(swift, contains('task.priority = URLSessionTask.highPriority'));
        expect(swift, contains('background.multipart.promote'));
        expect(swift, contains('values["attemptGeneration"] = attempt'));
      },
    );

    test(
      'multipart native bytes keep iOS continued-processing progress alive',
      () {
        final swift = File('ios/Runner/DownloadNativeWaitingQueue.swift')
            .readAsStringSync();
        final start = swift.indexOf(
          'private static func postMultipartChunkUpdate(',
        );
        final end = swift.indexOf('static func handleBytesWritten(', start);
        expect(start, greaterThanOrEqualTo(0));
        expect(end, greaterThan(start));
        final section = swift.substring(start, end);
        expect(section, contains('multipartChildSamples[parentId]'));
        expect(section, contains('state.runningSamples[parentId]'));
        expect(section, contains('overlayPresentation('));
        expect(section, contains('shouldUpdateNativeOverlay'));
        expect(section, contains('!isAppInForeground()'));
        expect(section, contains('upsertSessionOverlay('));
        expect(section, contains('never used as durable resume evidence'));
      },
    );
  });
}
