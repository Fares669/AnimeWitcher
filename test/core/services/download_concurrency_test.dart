import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

void main() {
  group('clampDownloadConcurrency', () {
    test('default sequential cap is 1', () {
      expect(kDownloadConcurrencyDefault, 1);
      expect(parseDownloadConcurrency(null), 1);
    });

    test('clamps to 1–5', () {
      expect(clampDownloadConcurrency(0), 1);
      expect(clampDownloadConcurrency(-3), 1);
      expect(clampDownloadConcurrency(1), 1);
      expect(clampDownloadConcurrency(3), 3);
      expect(clampDownloadConcurrency(5), 5);
      expect(clampDownloadConcurrency(6), 5);
      expect(clampDownloadConcurrency(10), 5);
    });

    test('parses numeric storage values and ignores junk', () {
      expect(parseDownloadConcurrency(4), 4);
      expect(parseDownloadConcurrency(4.9), 5);
      expect(parseDownloadConcurrency('3'), 1);
      expect(parseDownloadConcurrency(true), 1);
    });
  });

  group('holding queue tuple', () {
    test('uses the user N with unconstrained host and group', () {
      expect(downloadHoldingQueueValue(1), (1, null, null));
      expect(downloadHoldingQueueValue(3), (3, null, null));
      expect(downloadHoldingQueueValue(99), (5, null, null));

      final config = downloadHoldingQueueGlobalConfig(2);
      expect(config, hasLength(1));
      expect(config.single.$1, Config.holdingQueue);
      expect(config.single.$2, (2, null, null));
    });
  });

  group('applyDownloadQueueSettings', () {
    test(
      'writes the clamped value and the holding-queue configure tuple',
      () async {
        final storage = MemoryStorageService();
        List<(String, dynamic)>? configured;

        final applied = await applyDownloadQueueSettings(
          maxConcurrent: 9,
          persist: storage.setDownloadConcurrency,
          configure: (globalConfig) async {
            configured = globalConfig;
          },
        );

        expect(applied, 5);
        expect(storage.getDownloadConcurrency(), 5);
        expect(configured, <(String, dynamic)>[
          (Config.holdingQueue, (5, null, null)),
        ]);
      },
    );

    test(
      'sequential default persists as 1 and waits extras behind one slot',
      () async {
        final storage = MemoryStorageService();
        late List<(String, dynamic)> configured;

        await applyDownloadQueueSettings(
          maxConcurrent: 1,
          persist: storage.setDownloadConcurrency,
          configure: (globalConfig) async {
            configured = globalConfig;
          },
        );

        expect(storage.getDownloadConcurrency(), 1);
        expect(configured.single.$2, (1, null, null));
      },
    );
  });

  group('queue gate / overlay', () {
    test('waiting metadata is only the queueWaiting flag', () {
      expect(isQueueWaitingMetadata(null), isFalse);
      expect(isQueueWaitingMetadata({'queueWaiting': false}), isFalse);
      expect(
        isQueueWaitingMetadata({kDownloadQueueWaitingMetadataKey: true}),
        isTrue,
      );
    });

    test('only running/waitingToRetry occupy a transfer slot', () {
      expect(occupiesDownloadSlot(status: TaskStatus.running), isTrue);
      expect(occupiesDownloadSlot(status: TaskStatus.waitingToRetry), isTrue);
      expect(occupiesDownloadSlot(status: TaskStatus.enqueued), isFalse);
      expect(occupiesDownloadSlot(status: TaskStatus.paused), isFalse);
      expect(
        occupiesDownloadSlot(status: TaskStatus.enqueued, queueWaiting: true),
        isFalse,
      );
      expect(
        occupiesDownloadSlot(status: TaskStatus.paused, queueWaiting: true),
        isFalse,
      );
    });

    test('queue-waiting paused rows display as enqueued (في الانتظار)', () {
      expect(
        displayDownloadStatus(persisted: TaskStatus.paused, queueWaiting: true),
        TaskStatus.enqueued,
      );
      expect(
        displayDownloadStatus(
          persisted: TaskStatus.paused,
          queueWaiting: false,
        ),
        TaskStatus.paused,
      );
      expect(
        displayDownloadStatus(
          persisted: TaskStatus.running,
          queueWaiting: false,
        ),
        TaskStatus.running,
      );
      expect(
        displayDownloadStatus(
          persisted: TaskStatus.running,
          queueWaiting: true,
        ),
        TaskStatus.running,
      );
    });

    test('Live Activity starts only while a file is transferring', () {
      expect(shouldStartDownloadLiveActivity(TaskStatus.running), isTrue);
      expect(shouldStartDownloadLiveActivity(TaskStatus.enqueued), isFalse);
      expect(shouldStartDownloadLiveActivity(TaskStatus.paused), isFalse);
      expect(shouldStartDownloadLiveActivity(TaskStatus.complete), isFalse);
    });

    test(
      'must not finish the session overlay while any episode is running or waiting',
      () {
        expect(
          shouldFinishDownloadSessionOverlay(runningCount: 0, waitingCount: 1),
          isFalse,
        );
        expect(
          shouldFinishDownloadSessionOverlay(runningCount: 1, waitingCount: 4),
          isFalse,
        );
        expect(
          shouldFinishDownloadSessionOverlay(runningCount: 1, waitingCount: 0),
          isFalse,
        );
        expect(
          shouldFinishDownloadSessionOverlay(runningCount: 0, waitingCount: 0),
          isTrue,
        );
      },
    );

    test('one session overlay: filename title and 1-based current index', () {
      expect(kDownloadSessionOverlayTaskId, 'session');
      expect(
        formatDownloadSessionTitle(displayName: 'الحلقة 2.mp4'),
        'Downloading “الحلقة 2.mp4”',
      );
      expect(
        formatDownloadSessionSubtitle(
          transferredBytes: 40 * 1000 * 1000,
          totalBytes: 400 * 1000 * 1000,
          currentIndex: 1,
          batchTotal: 5,
        ),
        '40MB/400MB • 1 of 5',
      );
      expect(
        formatDownloadSessionSubtitle(
          transferredBytes: 12 * 1000 * 1000,
          totalBytes: 400 * 1000 * 1000,
          currentIndex: 2,
          batchTotal: 5,
          speedBytesPerSecond: 1.9 * 1000 * 1000,
        ),
        '1.9MB/s • 12MB/400MB • 2 of 5',
      );
      expect(
        formatDownloadSessionSubtitle(
          transferredBytes: 3200 * 1000,
          totalBytes: 6600 * 1000,
          currentIndex: 1,
          batchTotal: 3,
          speedBytesPerSecond: 85 * 1000,
        ),
        '85KB/s • 3.2MB/6.6MB • 1 of 3',
      );

      final whileEp1 = planDownloadOverlaySession(
        entries: const [
          DownloadOverlayEntry(
            taskId: 'ep1',
            status: TaskStatus.running,
            displayName: 'الحلقة 1',
            progress: 0.1,
            totalBytes: 400 * 1000 * 1000,
            speedBytesPerSecond: 1.9 * 1000 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep2',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 2',
          ),
          DownloadOverlayEntry(
            taskId: 'ep3',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 3',
          ),
          DownloadOverlayEntry(
            taskId: 'ep4',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 4',
          ),
          DownloadOverlayEntry(
            taskId: 'ep5',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 5',
          ),
        ],
      );
      expect(whileEp1.currentTaskId, 'ep1');
      expect(whileEp1.completedCount, 0);
      expect(whileEp1.currentIndex, 1);
      expect(overlayCurrentIndex(completedCount: 0, batchTotal: 3), 1);
      expect(overlayCurrentIndex(completedCount: 1, batchTotal: 3), 2);
      expect(overlayCurrentIndex(completedCount: 2, batchTotal: 3), 3);
      expect(whileEp1.batchTotal, 5);
      expect(whileEp1.transferredBytes, 40 * 1000 * 1000);
      expect(whileEp1.shouldFinish, isFalse);
      expect(
        formatDownloadSessionTitle(displayName: whileEp1.displayName),
        'Downloading “الحلقة 1”',
      );
      expect(
        formatDownloadSessionSubtitle(
          transferredBytes: whileEp1.transferredBytes,
          totalBytes: whileEp1.totalBytes,
          currentIndex: whileEp1.currentIndex,
          batchTotal: whileEp1.batchTotal,
        ),
        '40MB/400MB • 1 of 5',
      );

      final afterEp1 = planDownloadOverlaySession(
        entries: const [
          DownloadOverlayEntry(
            taskId: 'ep1',
            status: TaskStatus.complete,
            displayName: 'الحلقة 1',
            progress: 1,
            totalBytes: 400 * 1000 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep2',
            status: TaskStatus.running,
            displayName: 'الحلقة 2',
            progress: 0.03,
            totalBytes: 400 * 1000 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep3',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 3',
          ),
          DownloadOverlayEntry(
            taskId: 'ep4',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 4',
          ),
          DownloadOverlayEntry(
            taskId: 'ep5',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 5',
          ),
        ],
      );
      expect(afterEp1.currentTaskId, 'ep2');
      expect(afterEp1.completedCount, 1);
      expect(afterEp1.currentIndex, 2);
      expect(afterEp1.batchTotal, 5);
      expect(afterEp1.shouldFinish, isFalse);
      expect(
        formatDownloadSessionTitle(displayName: afterEp1.displayName),
        'Downloading “الحلقة 2”',
      );
      expect(
        formatDownloadSessionSubtitle(
          transferredBytes: afterEp1.transferredBytes,
          totalBytes: afterEp1.totalBytes,
          currentIndex: afterEp1.currentIndex,
          batchTotal: afterEp1.batchTotal,
        ),
        '12MB/400MB • 2 of 5',
      );

      final allDone = planDownloadOverlaySession(
        entries: const [
          DownloadOverlayEntry(
            taskId: 'ep1',
            status: TaskStatus.complete,
            displayName: 'الحلقة 1',
          ),
          DownloadOverlayEntry(
            taskId: 'ep2',
            status: TaskStatus.complete,
            displayName: 'الحلقة 2',
          ),
        ],
      );
      expect(allDone.completedCount, 2);
      expect(allDone.runningCount, 0);
      expect(allDone.waitingCount, 0);
      expect(allDone.shouldFinish, isTrue);
    });

    test('overflow is OS-enqueued; overlay starts only when running', () {
      expect(shouldStartDownloadLiveActivity(TaskStatus.enqueued), isFalse);
      expect(shouldStartDownloadLiveActivity(TaskStatus.running), isTrue);
    });

    test(
      'native snapshot waiters are HQ enqueued + leftover parked, never user-paused',
      () {
        expect(
          isNativeWaitingSnapshotWaiter(
            status: TaskStatus.enqueued,
            queueWaiting: false,
            userPaused: false,
          ),
          isTrue,
        );
        expect(
          isNativeWaitingSnapshotWaiter(
            status: TaskStatus.paused,
            queueWaiting: true,
            userPaused: false,
          ),
          isTrue,
        );
        expect(
          isNativeWaitingSnapshotWaiter(
            status: TaskStatus.paused,
            queueWaiting: false,
            userPaused: true,
          ),
          isFalse,
        );
        expect(
          isNativeWaitingSnapshotWaiter(
            status: TaskStatus.running,
            queueWaiting: false,
            userPaused: false,
          ),
          isFalse,
        );
      },
    );

    test(
      'native waiter payload has url, headers, filename, directory, task JSON',
      () {
        final task = DownloadTask(
          taskId: 'ep2',
          url: 'https://cdn.test/ep2.mp4',
          filename: 'الحلقة 2.mp4',
          directory: 'AnimeWitcher/Downloads/Show',
          headers: const {'Authorization': 'Bearer x'},
          displayName: 'الحلقة 2.mp4',
        );
        final payload = nativeWaitingPayload(task);
        expect(nativeWaiterPayloadIsComplete(payload), isTrue);
        expect(payload['taskId'], 'ep2');
        expect(payload['url'], 'https://cdn.test/ep2.mp4');
        expect(payload['filename'], 'الحلقة 2.mp4');
        expect(payload['directory'], 'AnimeWitcher/Downloads/Show');
        expect(payload['headers'], containsPair('Authorization', 'Bearer x'));
        expect(payload['headers'], isA<Map<String, String>>());
        expect(payload['taskJson'], contains('https://cdn.test/ep2.mp4'));
        expect(payload['taskJson'], contains('ep2'));
        expect(
          nativeWaiterPayloadIsComplete({'taskId': 'ep2', 'url': ''}),
          isFalse,
        );
      },
    );

    test(
      'iOS concurrency=1, two episodes: waiter is enqueued, overlay only when running',
      () {
        final whileEp1Transfers = planDownloadQueue(
          maxConcurrent: 1,
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep1',
              status: TaskStatus.running,
              timestamp: 1,
            ),
            DownloadQueueEntry(
              taskId: 'ep2',
              status: TaskStatus.enqueued,
              timestamp: 2,
            ),
          ],
        );
        expect(whileEp1Transfers.occupiedCount, 1);
        expect(whileEp1Transfers.waitingFifoIds, ['ep2']);
        expect(whileEp1Transfers.idsToPromote, isEmpty);
        expect(shouldStartDownloadLiveActivity(TaskStatus.running), isTrue);
        expect(shouldStartDownloadLiveActivity(TaskStatus.enqueued), isFalse);

        final afterEp1Finishes = planDownloadQueue(
          maxConcurrent: 1,
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep1',
              status: TaskStatus.complete,
              timestamp: 1,
            ),
            DownloadQueueEntry(
              taskId: 'ep2',
              status: TaskStatus.enqueued,
              timestamp: 2,
            ),
          ],
        );
        expect(afterEp1Finishes.occupiedCount, 0);
        expect(afterEp1Finishes.waitingFifoIds, ['ep2']);
        expect(afterEp1Finishes.idsToPromote, isEmpty);
        expect(
          shouldAttachToLiveNativeTask(
            taskId: 'ep2',
            trackingUrl: 'https://cdn.test/ep2',
            live: const [
              LiveNativeDownload(
                taskId: 'ep2',
                trackingUrl: 'https://cdn.test/ep2',
              ),
            ],
          ),
          isTrue,
        );
        expect(shouldStartDownloadLiveActivity(TaskStatus.running), isTrue);
        expect(shouldStartDownloadLiveActivity(TaskStatus.enqueued), isFalse);
      },
    );

    test(
      'leftover Dart-parked waiters re-enqueue FIFO; user-paused stays paused',
      () {
        final planWhileRunning = planDownloadQueue(
          maxConcurrent: 1,
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep3',
              status: TaskStatus.running,
              timestamp: 1,
            ),
            DownloadQueueEntry(
              taskId: 'ep4',
              status: TaskStatus.paused,
              timestamp: 2,
              queueWaiting: true,
            ),
            DownloadQueueEntry(
              taskId: 'ep5-user-paused',
              status: TaskStatus.paused,
              timestamp: 0,
            ),
          ],
        );
        expect(planWhileRunning.occupiedCount, 1);
        expect(planWhileRunning.waitingFifoIds, ['ep4']);
        expect(planWhileRunning.idsToPromote, isEmpty);
        expect(shouldStartDownloadLiveActivity(TaskStatus.enqueued), isFalse);

        final afterComplete = planDownloadQueue(
          maxConcurrent: 1,
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep3',
              status: TaskStatus.complete,
              timestamp: 1,
            ),
            DownloadQueueEntry(
              taskId: 'ep4',
              status: TaskStatus.paused,
              timestamp: 2,
              queueWaiting: true,
            ),
            DownloadQueueEntry(
              taskId: 'ep5-user-paused',
              status: TaskStatus.paused,
              timestamp: 0,
            ),
          ],
        );
        expect(afterComplete.occupiedCount, 0);
        expect(afterComplete.idsToPromote, ['ep4']);
        expect(afterComplete.idsToPromote, isNot(contains('ep5-user-paused')));
      },
    );

    test(
      'in-app complete starts the oldest waiter; user-paused stays paused',
      () {
        final stuckLikeRivera = planDownloadQueue(
          maxConcurrent: 1,
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep2',
              status: TaskStatus.complete,
              timestamp: 1,
            ),
            DownloadQueueEntry(
              taskId: 'ep3',
              status: TaskStatus.paused,
              timestamp: 2,
              queueWaiting: true,
            ),
          ],
        );
        expect(stuckLikeRivera.occupiedCount, 0);
        expect(stuckLikeRivera.idsToPromote, ['ep3']);
        expect(shouldStartDownloadLiveActivity(TaskStatus.enqueued), isFalse);
        expect(shouldStartDownloadLiveActivity(TaskStatus.running), isTrue);

        final twoWaiters = planDownloadQueue(
          maxConcurrent: 1,
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep2',
              status: TaskStatus.complete,
              timestamp: 1,
            ),
            DownloadQueueEntry(
              taskId: 'ep3',
              status: TaskStatus.paused,
              timestamp: 2,
              queueWaiting: true,
            ),
            DownloadQueueEntry(
              taskId: 'ep4',
              status: TaskStatus.paused,
              timestamp: 3,
              queueWaiting: true,
            ),
          ],
        );
        expect(twoWaiters.idsToPromote, ['ep3']);
        expect(twoWaiters.waitingFifoIds, ['ep3', 'ep4']);
      },
    );

    test(
      'never start a second transfer when native already owns the episode',
      () {
        expect(
          shouldAttachToLiveNativeTask(
            taskId: 'ep2',
            trackingUrl: 'https://show/ep2',
            live: const [
              LiveNativeDownload(
                taskId: 'ep2',
                trackingUrl: 'https://show/ep2',
              ),
            ],
          ),
          isTrue,
        );
        expect(
          shouldAttachToLiveNativeTask(
            taskId: 'dart-parked',
            trackingUrl: 'https://show/ep2',
            live: const [
              LiveNativeDownload(
                taskId: 'native-ep2',
                trackingUrl: 'https://show/ep2',
              ),
            ],
          ),
          isTrue,
        );
        expect(
          shouldAttachToLiveNativeTask(
            taskId: 'ep3',
            trackingUrl: 'https://show/ep3',
            live: const [
              LiveNativeDownload(
                taskId: 'ep2',
                trackingUrl: 'https://show/ep2',
              ),
            ],
          ),
          isFalse,
        );
        expect(progressMeansNativeTransfer(0), isFalse);
        expect(progressMeansNativeTransfer(0.01), isTrue);
        expect(
          isCompleteDownloadCredible(progress: 0.01, expectedBytes: 6100000),
          isFalse,
        );
        expect(
          isCompleteDownloadCredible(progress: 1.0, expectedBytes: 6100000),
          isTrue,
        );
        expect(isCompleteDownloadCredible(), isTrue);
      },
    );

    test('lowering N never detaches occupying URLSession tasks', () {
      final plan = planDownloadQueue(
        maxConcurrent: 1,
        entries: const [
          DownloadQueueEntry(
            taskId: 'older',
            status: TaskStatus.running,
            timestamp: 10,
          ),
          DownloadQueueEntry(
            taskId: 'newer',
            status: TaskStatus.running,
            timestamp: 20,
          ),
        ],
      );
      expect(plan.idsToPromote, isEmpty);
      expect(plan.occupiedCount, 2);
    });

    test('kill recovery re-enqueues waiters, never user-paused rows', () {
      expect(
        shouldReenqueueWaitingAfterProcessKill(
          persisted: TaskStatus.enqueued,
          queueWaiting: false,
          userPaused: false,
          stillInNativeQueue: false,
        ),
        isTrue,
      );
      expect(
        shouldReenqueueWaitingAfterProcessKill(
          persisted: TaskStatus.paused,
          queueWaiting: true,
          userPaused: false,
          stillInNativeQueue: false,
        ),
        isTrue,
      );
      expect(
        shouldReenqueueWaitingAfterProcessKill(
          persisted: TaskStatus.paused,
          queueWaiting: false,
          userPaused: true,
          stillInNativeQueue: false,
        ),
        isFalse,
      );
      expect(
        shouldReenqueueWaitingAfterProcessKill(
          persisted: TaskStatus.enqueued,
          queueWaiting: false,
          userPaused: false,
          stillInNativeQueue: true,
        ),
        isFalse,
      );
      expect(
        shouldReenqueueWaitingAfterProcessKill(
          persisted: TaskStatus.running,
          queueWaiting: false,
          userPaused: false,
          stillInNativeQueue: false,
        ),
        isFalse,
      );
    });
  });

  group('SettingsRepository download concurrency', () {
    test('defaults to 1 and clamps writes', () async {
      final storage = MemoryStorageService();
      final repository = SettingsRepository(storage);

      expect(repository.getDownloadConcurrency(), 1);
      await repository.setDownloadConcurrency(0);
      expect(repository.getDownloadConcurrency(), 1);
      await repository.setDownloadConcurrency(4);
      expect(repository.getDownloadConcurrency(), 4);
      await repository.setDownloadConcurrency(99);
      expect(repository.getDownloadConcurrency(), 5);
    });
  });
}
