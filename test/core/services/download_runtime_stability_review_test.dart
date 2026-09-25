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
      expect(source, contains('await _restoreNativeOwnership(session);'));
      expect(source, contains('await _status(session, TaskStatus.running);'));
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
    test(
      'multipart manifests persist generation, byte and resource identity',
      () {
        final source = File(
          'lib/core/services/persistent_parallel_download.dart',
        ).readAsStringSync();
        expect(source, contains('kParallelManifestSchemaVersion = 6'));
        expect(
          source,
          contains("'schemaVersion': kParallelManifestSchemaVersion"),
        );
        expect(source, contains("'generation': session.generation"));
        expect(source, contains("'parentTask': session.task.toJson()"));
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
    test('steady multipart progress does not rescan the scheduler', () {
      final source = File('lib/core/services/persistent_parallel_download.dart')
          .readAsStringSync();

      final nativeStart = source.indexOf('Future<void> handleNativeChunkUpdate');
      final nativeEnd = source.indexOf('bool handleUpdate(', nativeStart);
      expect(nativeStart, greaterThanOrEqualTo(0));
      expect(nativeEnd, greaterThan(nativeStart));
      expect(
        source.substring(nativeStart, nativeEnd),
        isNot(contains('_schedulePumpAll();')),
      );

      final progressStart = source.indexOf('if (update is TaskProgressUpdate');
      final progressEnd = source.indexOf(
        'if (update is! TaskStatusUpdate) return;',
        progressStart,
      );
      expect(progressStart, greaterThanOrEqualTo(0));
      expect(progressEnd, greaterThan(progressStart));
      expect(
        source.substring(progressStart, progressEnd),
        isNot(contains('_schedulePumpAll();')),
      );
    });

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
        expect(parallel, contains('part.progress > 0 ||'));
        expect(parallel, contains('part.credibleProgress > 0'));
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
