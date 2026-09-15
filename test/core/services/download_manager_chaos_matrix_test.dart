import 'dart:async';

import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_continued_processing_service.dart';
import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_job_store.dart';
import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/download_retry_policy.dart';
import 'package:animewitcher/core/services/download_service.dart';
import 'package:animewitcher/core/services/download_transport.dart';
import 'package:animewitcher/core/services/download_transport_policy.dart';
import 'package:animewitcher/core/services/download_url_refresh.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

class _ChaosJobBackend implements DownloadJobBackend {
  final Map<String, Map<String, dynamic>> values =
      <String, Map<String, dynamic>>{};

  @override
  Future<void> delete(String taskId) async {
    values.remove(taskId);
  }

  @override
  Future<Map<String, dynamic>?> read(String taskId) async {
    final value = values[taskId];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  @override
  Future<List<Map<String, dynamic>>> readAll() async => values.values
      .map((value) => Map<String, dynamic>.from(value))
      .toList(growable: false);

  @override
  Future<void> write(String taskId, Map<String, Object?> value) async {
    values[taskId] = Map<String, dynamic>.from(value);
  }
}

DownloadJobRecord _chaosSeed({
  String taskId = 'episode-7',
  int durableBytes = 40,
  DownloadJobState state = DownloadJobState.interrupted,
}) => DownloadJobRecord(
  taskId: taskId,
  logicalId: 'show-7',
  trackingUrl: 'https://anime.test/episode/7',
  state: state,
  generation: 0,
  durableBytes: durableBytes,
  durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
  expectedBytes: 100,
  userPaused: false,
  queueWaiting: false,
  updatedAtMillis: 1,
  fingerprint: const DownloadResourceFingerprint(
    strongEtag: '"episode-seven"',
    expectedBytes: 100,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DM-18 deterministic chaos matrix converges without a second writer', () async {
    final backend = _ChaosJobBackend();
    final store = DownloadJobStore(backend);
    expect(await store.put(_chaosSeed()), isTrue);

    // Start, retry, and deliver the old callback after the new generation has
    // become current. The old callback must not restore bytes or state.
    final first = await store.beginAttempt(
      'episode-7',
      state: DownloadJobState.running,
      updatedAtMillis: 2,
    );
    expect(first, isNotNull);
    expect(
      await store.updateForAttempt(
        first!,
        durableBytes: 55,
        durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,
        updatedAtMillis: 3,
      ),
      isTrue,
    );

    final retry = await store.beginAttempt(
      'episode-7',
      state: DownloadJobState.starting,
      updatedAtMillis: 4,
    );
    expect(retry, isNotNull);
    expect(retry!.generation, greaterThan(first.generation));
    expect(
      await store.updateForAttempt(
        first,
        state: DownloadJobState.pausedByUser,
        durableBytes: 99,
        durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,
      ),
      isFalse,
      reason: 'late callbacks from the old execution are fenced',
    );
    expect(
      await store.updateForAttempt(
        retry,
        state: DownloadJobState.running,
        durableBytes: 60,
        durableByteProvenance: DownloadDurableByteProvenance.nativeRecoverable,
        updatedAtMillis: 5,
      ),
      isTrue,
    );

    // A stronger exact-disk observation may correct bytes downward. That
    // correction advances the generation and fences the pre-reconciliation
    // writer before a new range writer is allowed to start.
    final corrected = await store.reconcileDurableBytes(
      retry,
      durableBytes: 24,
      evidenceProvenance: DownloadDurableByteProvenance.exactDisk,
      reason: DownloadByteReconciliationReason.exactDiskLoss,
      updatedAtMillis: 6,
    );
    expect(corrected, isNotNull);
    expect(corrected!.generation, greaterThan(retry.generation));
    expect(
      await store.updateForAttempt(
        retry,
        durableBytes: 88,
        durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,
      ),
      isFalse,
    );
    final current = await store.get('episode-7');
    expect(current?.durableBytes, 24);
    expect(current?.durableByteProvenance, DownloadDurableByteProvenance.exactDisk);
    expect(
      current?.lastByteReconciliationReason,
      DownloadByteReconciliationReason.exactDiskLoss,
    );

    // A command acknowledgement is not ownership settlement. Unknown and
    // settling both keep a second writer out until the runtime oracle clears.
    expect(
      resolveDownloadCancelCommand(
        hadTrackedOwner: true,
        commandSucceeded: false,
        commandThrew: true,
      ),
      DownloadCancelSettlement.unknown,
    );
    expect(
      resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: false,
        runtimeTaskPresent: false,
      ).blocksNewWriter,
      isTrue,
    );
    expect(
      resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: false,
        operationSettling: true,
      ).blocksNewWriter,
      isTrue,
    );
    expect(
      resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: false,
      ),
      DownloadRuntimeOwnership.notOwned,
    );
  });

  test('DM-18 matrix covers queue, multipart, bytes, and platform policy boundaries', () {
    final entries = <DownloadQueueEntry>[
      const DownloadQueueEntry(
        taskId: 'active-1',
        status: TaskStatus.running,
        timestamp: 1,
      ),
      const DownloadQueueEntry(
        taskId: 'active-2',
        status: TaskStatus.running,
        timestamp: 2,
      ),
      const DownloadQueueEntry(
        taskId: 'parked-1',
        status: TaskStatus.paused,
        queueWaiting: true,
        timestamp: 3,
      ),
      const DownloadQueueEntry(
        taskId: 'parked-2',
        status: TaskStatus.paused,
        queueWaiting: true,
        timestamp: 4,
      ),
      const DownloadQueueEntry(
        taskId: 'user-paused',
        status: TaskStatus.paused,
        userPaused: true,
        timestamp: 5,
      ),
    ];

    for (final requested in <int>[1, 2, 5, 8, 10, 16]) {
      final plan = planDownloadQueue(
        maxConcurrent: requested,
        entries: entries,
      );
      final expectedCap = clampDownloadConcurrency(requested);
      expect(plan.maxConcurrent, expectedCap, reason: 'requested=$requested');
      expect(plan.occupiedCount, 2, reason: 'requested=$requested');
      expect(plan.idsToPromote.length, lessThanOrEqualTo(plan.freeSlots));
      expect(plan.idsToPromote, orderedEquals(['parked-1', 'parked-2'].take(plan.freeSlots)));
      expect(plan.idsToPromote, isNot(contains('user-paused')));
    }

    final template = DownloadTask(
      taskId: 'episode-16',
      url: 'https://anime.test/episode-16.mp4',
      filename: 'episode-16.mp4',
      group: kLogicalDownloadGroup,
      metaData: 'episode:16',
    );
    for (final parts in <int>[1, 2, 5, 8, 16]) {
      final task = buildAdaptiveDownloadTask(template: template, parts: parts);
      expect(task.taskId, template.taskId, reason: 'parts=$parts');
      expect(downloadTaskPartCount(task), parts == 1 ? 1 : parts);
      expect(isLogicalEpisodeDownloadTask(task), isTrue);
    }

    for (final android in <bool>[false, true]) {
      for (final configured in <bool>[false, true]) {
        for (final permission in <bool>[false, true]) {
          final eligible = shouldUseUserInitiatedDownloadHint(
            isAndroid: android,
            notificationsConfigured: configured,
            notificationPermissionGranted: permission,
          );
          final expectedEligible = android ? configured && permission : true;
          expect(
            eligible,
            expectedEligible,
            reason: 'android=$android configured=$configured permission=$permission',
          );
          final hints = animeDownloadTransferHints(
            expectedBytes: 900 * 1024 * 1024,
            useUserInitiated: eligible,
          );
          expect(hints, contains(TransferHint.largeFile));
          expect(hints.contains(TransferHint.userInitiated), eligible);
        }
      }
    }

    expect(
      selectDownloadRecoveryBytes().source,
      DownloadRecoveryByteSource.none,
      reason: 'percentage-only evidence never becomes durable bytes',
    );
    expect(
      selectDownloadRecoveryBytes(
        exactDiskBytes: 24,
        currentGenerationJobBytes: 60,
        multipartManifestBytes: 55,
      ).bytes,
      24,
    );
  });

  test('Task 13 runs reliability decisions through legacy and plugin parallel modes', () {
    final template = DownloadTask(
      taskId: 'episode-chaos',
      url: 'https://cdn.test/signed/episode.mp4?token=old',
      filename: 'episode-chaos.mp4',
      group: kLogicalDownloadGroup,
      metaData: 'episode:chaos',
    );

    for (final accepted in <bool>[false, true]) {
      final backend = selectDownloadExecutionBackend(
        connections: 8,
        pluginParallelAccepted: accepted,
        legacySessionExists: false,
      );
      expect(
        backend,
        accepted
            ? DownloadExecutionBackend.pluginParallel
            : DownloadExecutionBackend.legacyParallel,
      );
      if (backend == DownloadExecutionBackend.pluginParallel) {
        final task = buildPluginTransportTask(
          template: template,
          connections: 8,
        );
        expect(task, isA<ParallelDownloadTask>());
        expect(task.taskId, template.taskId);
        expect(task.group, kLogicalDownloadGroup);
        expect(downloadTaskPartCount(task), 8);
      }
    }

    expect(
      selectDownloadExecutionBackend(
        connections: 8,
        pluginParallelAccepted: true,
        legacySessionExists: true,
      ),
      DownloadExecutionBackend.legacyParallel,
      reason: 'persisted PR #231 ownership wins over fresh plugin admission',
    );

    expect(
      planDownloadFailure(statusCode: 403, canRefreshUrl: true).action,
      DownloadFailureAction.refreshUrl,
      reason: 'signed URL expiry remains an application-level refresh action',
    );
    expect(
      planRefreshedTransferResume(
        resourceCompatible: true,
        hasPartialBytes: true,
        pluginCanResumeChangedSource: false,
      ),
      RefreshedTransferResumeMode.verifiedRangeFallback,
      reason: 'saved compatible bytes are never silently restarted',
    );
    expect(
      planDownloadFailure(noSpaceLeft: true).action,
      DownloadFailureAction.stopNoSpace,
      reason: 'low disk stops transport rather than retrying blindly',
    );

    expect(
      ownershipFromStatus(TaskStatus.running),
      DownloadRuntimeOwnership.owned,
    );
    expect(
      ownershipFromStatus(TaskStatus.paused),
      DownloadRuntimeOwnership.notOwned,
      reason: 'pause settlement releases the writer slot before resume',
    );
    expect(
      resolveDownloadCancelCommand(
        hadTrackedOwner: true,
        commandSucceeded: true,
        commandThrew: false,
      ),
      DownloadCancelSettlement.canceled,
      reason: 'cancel command success is only the command acknowledgement',
    );
    expect(
      resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: false,
        operationSettling: true,
      ),
      DownloadRuntimeOwnership.settling,
      reason: 'runtime settlement still blocks a replacement writer',
    );
  });

  test('DM-18 matrix joins teardown and fences the old native handler lease', () async {
    final barrier = DownloadServiceTeardownBarrier();
    final releaseTeardown = Completer<void>();
    var oldTeardownFinished = false;
    var replacementStarted = false;

    final oldTeardown = barrier.run(() async {
      await releaseTeardown.future;
      oldTeardownFinished = true;
    });
    final replacement = barrier.wait().then((_) {
      replacementStarted = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(replacementStarted, isFalse);
    expect(oldTeardownFinished, isFalse);

    releaseTeardown.complete();
    await oldTeardown;
    await replacement;
    expect(oldTeardownFinished, isTrue);
    expect(replacementStarted, isTrue);

    final oldLease = DownloadGlobalHandlerLease.acquire();
    final currentLease = DownloadGlobalHandlerLease.acquire();
    expect(oldLease.releaseIfCurrent(), isFalse);
    expect(currentLease.releaseIfCurrent(), isTrue);
  });
}
