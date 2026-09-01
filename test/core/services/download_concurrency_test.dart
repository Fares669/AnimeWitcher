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
        expect(
          downloadSessionHasRemainingWork(
            runningCount: 0,
            waitingCount: 0,
            pendingWaiterPayloads: 3,
          ),
          isTrue,
        );
        expect(
          downloadSessionHasRemainingWork(
            runningCount: 0,
            waitingCount: 0,
            pendingWaiterPayloads: 0,
          ),
          isFalse,
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

      final afterEp1BeforeBytes = planDownloadOverlaySession(
        entries: const [
          DownloadOverlayEntry(
            taskId: 'ep1',
            status: TaskStatus.complete,
            displayName: 'الحلقة 1',
            progress: 1,
            totalBytes: 10 * 1000 * 1000,
            speedBytesPerSecond: 859 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep2',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 11 (480p).mp4',
            totalBytes: 10 * 1000 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep3',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 12',
          ),
          DownloadOverlayEntry(
            taskId: 'ep4',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 13',
          ),
        ],
      );
      expect(afterEp1BeforeBytes.currentTaskId, 'ep2');
      expect(afterEp1BeforeBytes.currentIndex, 2);
      expect(afterEp1BeforeBytes.transferredBytes, 0);
      expect(afterEp1BeforeBytes.speedBytesPerSecond, 0);
      expect(afterEp1BeforeBytes.shouldFinish, isFalse);
      expect(
        formatDownloadSessionSubtitle(
          transferredBytes: afterEp1BeforeBytes.transferredBytes,
          totalBytes: afterEp1BeforeBytes.totalBytes,
          currentIndex: afterEp1BeforeBytes.currentIndex,
          batchTotal: afterEp1BeforeBytes.batchTotal,
        ),
        '0B/10MB • 2 of 4',
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

    test('overlay k of N follows enqueue FIFO', () {
      final session = planDownloadOverlaySession(
        queueOrder: const ['ep1', 'ep2', 'ep3'],
        entries: const [
          DownloadOverlayEntry(
            taskId: 'ep1',
            status: TaskStatus.running,
            displayName: 'الحلقة 1',
            progress: 0.2,
            totalBytes: 1000,
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
        ],
      );
      expect(session.currentTaskId, 'ep1');
      expect(session.currentIndex, 1);
      expect(session.batchTotal, 3);
      expect(
        formatDownloadSessionSubtitle(
          transferredBytes: session.transferredBytes,
          totalBytes: session.totalBytes,
          currentIndex: session.currentIndex,
          batchTotal: session.batchTotal,
        ),
        '200B/1KB • 1 of 3',
      );
    });

    test('overlay stays on the running file while waiters wait', () {
      final after = planDownloadOverlaySession(
        queueOrder: const ['ep7', 'ep8', 'ep9'],
        entries: const [
          DownloadOverlayEntry(
            taskId: 'ep7',
            status: TaskStatus.running,
            displayName: 'الحلقة 7',
            progress: 0.01,
            totalBytes: 10 * 1000 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep8',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 8',
            queueWaiting: true,
          ),
          DownloadOverlayEntry(
            taskId: 'ep9',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 9',
          ),
        ],
      );
      expect(after.currentTaskId, 'ep7');
      expect(after.waitingCount, 2);
      expect(after.runningCount, 1);
      expect(after.displayName, 'الحلقة 7');
      expect(after.shouldFinish, isFalse);
    });

    test('N>1 overlay sums running bytes and uses started-count', () {
      final concurrent = planDownloadOverlaySession(
        entries: const [
          DownloadOverlayEntry(
            taskId: 'ep1',
            status: TaskStatus.running,
            displayName: 'الحلقة 1.mp4',
            progress: 0.1,
            totalBytes: 100 * 1000 * 1000,
            speedBytesPerSecond: 10 * 1000 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep2',
            status: TaskStatus.running,
            displayName: 'الحلقة 2.mp4',
            progress: 0.1,
            totalBytes: 200 * 1000 * 1000,
            speedBytesPerSecond: 20 * 1000 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep3',
            status: TaskStatus.running,
            displayName: 'الحلقة 3.mp4',
            progress: 0.1,
            totalBytes: 50 * 1000 * 1000,
            speedBytesPerSecond: 5 * 1000 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep4',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 4.mp4',
          ),
          DownloadOverlayEntry(
            taskId: 'ep5',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 5.mp4',
          ),
        ],
      );
      expect(concurrent.displayName, 'الحلقة 1.mp4');
      expect(concurrent.currentIndex, 3);
      expect(concurrent.batchTotal, 5);
      expect(concurrent.transferredBytes, 35 * 1000 * 1000);
      expect(concurrent.totalBytes, 350 * 1000 * 1000);
      expect(
        formatDownloadSessionSubtitle(
          transferredBytes: concurrent.transferredBytes,
          totalBytes: concurrent.totalBytes,
          currentIndex: concurrent.currentIndex,
          batchTotal: concurrent.batchTotal,
          speedBytesPerSecond: concurrent.speedBytesPerSecond,
        ),
        '35.0MB/s • 35MB/350MB • 3 of 5',
      );

      final later = planDownloadOverlaySession(
        entries: const [
          DownloadOverlayEntry(
            taskId: 'ep1',
            status: TaskStatus.complete,
            displayName: 'الحلقة 1.mp4',
          ),
          DownloadOverlayEntry(
            taskId: 'ep2',
            status: TaskStatus.complete,
            displayName: 'الحلقة 2.mp4',
          ),
          DownloadOverlayEntry(
            taskId: 'ep3',
            status: TaskStatus.running,
            displayName: 'الحلقة 3.mp4',
            progress: 0.5,
            totalBytes: 100 * 1000 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep4',
            status: TaskStatus.running,
            displayName: 'الحلقة 4.mp4',
            progress: 0.5,
            totalBytes: 100 * 1000 * 1000,
          ),
          DownloadOverlayEntry(
            taskId: 'ep5',
            status: TaskStatus.running,
            displayName: 'الحلقة 5.mp4',
            progress: 0.5,
            totalBytes: 100 * 1000 * 1000,
          ),
        ],
      );
      expect(later.currentIndex, 5);
      expect(later.batchTotal, 5);
      expect(later.displayName, 'الحلقة 3.mp4');
      expect(later.transferredBytes, 150 * 1000 * 1000);
      expect(later.totalBytes, 300 * 1000 * 1000);
      expect(
        formatDownloadSessionSubtitle(
          transferredBytes: later.transferredBytes,
          totalBytes: later.totalBytes,
          currentIndex: later.currentIndex,
          batchTotal: later.batchTotal,
        ),
        '150MB/300MB • 5 of 5',
      );
    });

    test('new downloads append at the bottom of the FIFO', () {
      expect(appendDownloadQueueId(const ['ep1'], 'ep2'), ['ep1', 'ep2']);
      expect(appendDownloadQueueId(const ['ep1', 'ep2'], 'ep1'), [
        'ep1',
        'ep2',
      ]);
      expect(removeDownloadQueueIds(const ['ep1', 'ep2', 'ep3'], ['ep2']), [
        'ep1',
        'ep3',
      ]);
    });

    test('foreground attach keeps last known speed until the next tick', () {
      expect(
        keepLastKnownDownloadSpeed(
          status: TaskStatus.running,
          incomingSpeed: 0,
          lastKnownSpeed: 0.64,
        ),
        0.64,
      );
      expect(
        keepLastKnownDownloadSpeed(
          status: TaskStatus.running,
          incomingSpeed: 1.2,
          lastKnownSpeed: 0.64,
        ),
        1.2,
      );
      expect(
        keepLastKnownDownloadSpeed(
          status: TaskStatus.paused,
          incomingSpeed: 0,
          lastKnownSpeed: 0.64,
        ),
        0,
      );
    });

    test('overlay speed resets on file switch, keeps hitch on same file', () {
      expect(
        overlayNativeSpeedUpdate(
          currentTaskId: 'ep1',
          previousTaskId: 'ep1',
          runningCount: 1,
          plannedSpeed: 0,
        ),
        -1,
      );
      expect(
        overlayNativeSpeedUpdate(
          currentTaskId: 'ep2',
          previousTaskId: 'ep1',
          runningCount: 0,
          plannedSpeed: 859 * 1000,
        ),
        0,
      );
      expect(
        overlayNativeSpeedUpdate(
          currentTaskId: 'ep2',
          previousTaskId: 'ep1',
          runningCount: 1,
          plannedSpeed: 0,
        ),
        0,
      );
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

        final resumePayload = nativeWaitingPayload(
          task,
          resumeDataBase64: 'cmVzdW1l',
          progress: 0.42,
          expectedBytes: 8000,
        );
        expect(resumePayload['resumeDataBase64'], 'cmVzdW1l');
        expect(resumePayload['progress'], 0.42);
        expect(resumePayload['expectedBytes'], 8000);
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

    test('a failed episode parks paused and the next waiter starts', () {
      expect(shouldParkFailedDownloadAsPaused(TaskStatus.failed), isTrue);
      expect(shouldParkFailedDownloadAsPaused(TaskStatus.notFound), isTrue);
      expect(shouldParkFailedDownloadAsPaused(TaskStatus.complete), isFalse);
      expect(
        shouldParkSystemCanceledDownload(
          status: TaskStatus.canceled,
          userCancel: true,
        ),
        isFalse,
      );
      expect(
        shouldParkSystemCanceledDownload(
          status: TaskStatus.canceled,
          userCancel: false,
        ),
        isTrue,
      );
      expect(kDownloadTaskRetries, 0);
      expect(kDownloadParkedNotificationBody, 'التنزيل متوقف مؤقتاً');
      expect(
        downloadSessionFinishStatus(success: false, parkedFailure: true),
        'canceled',
      );
      expect(
        downloadSessionFinishStatus(success: true, parkedFailure: true),
        'canceled',
      );
      expect(
        downloadSessionFinishStatus(success: true, parkedFailure: false),
        'completed',
      );

      const afterEp2Failed = [
        DownloadQueueEntry(
          taskId: 'ep5',
          status: TaskStatus.paused,
          timestamp: 1,
        ),
        DownloadQueueEntry(
          taskId: 'ep7',
          status: TaskStatus.enqueued,
          timestamp: 2,
        ),
        DownloadQueueEntry(
          taskId: 'ep9',
          status: TaskStatus.enqueued,
          timestamp: 3,
        ),
      ];
      expect(occupiesDownloadSlot(status: TaskStatus.failed), isFalse);
      expect(occupiesDownloadSlot(status: TaskStatus.paused), isFalse);
      final plan = planDownloadQueue(
        maxConcurrent: 1,
        entries: afterEp2Failed,
        queueOrder: const ['ep5', 'ep7', 'ep9'],
      );
      expect(plan.occupiedCount, 0);
      expect(plan.waitingFifoIds, ['ep7', 'ep9']);
      expect(
        idsToStartAfterParkedFailure(
          maxConcurrent: 1,
          entries: afterEp2Failed,
          queueOrder: const ['ep5', 'ep7', 'ep9'],
        ),
        ['ep7'],
      );

      final leftover = idsToStartAfterParkedFailure(
        maxConcurrent: 1,
        entries: const [
          DownloadQueueEntry(
            taskId: 'ep5',
            status: TaskStatus.paused,
            timestamp: 1,
          ),
          DownloadQueueEntry(
            taskId: 'ep7',
            status: TaskStatus.paused,
            timestamp: 2,
            queueWaiting: true,
          ),
        ],
      );
      expect(leftover, ['ep7']);

      final overlay = planDownloadOverlaySession(
        entries: const [
          DownloadOverlayEntry(
            taskId: 'ep5',
            status: TaskStatus.paused,
            displayName: 'الحلقة 5',
            progress: 0.5,
          ),
          DownloadOverlayEntry(
            taskId: 'ep7',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 7',
          ),
          DownloadOverlayEntry(
            taskId: 'ep9',
            status: TaskStatus.enqueued,
            displayName: 'الحلقة 9',
          ),
        ],
        queueOrder: const ['ep5', 'ep7', 'ep9'],
      );
      expect(overlay.runningCount, 0);
      expect(overlay.waitingCount, 2);
      expect(overlay.shouldFinish, isFalse);
      expect(overlay.currentTaskId, 'ep7');
      expect(
        downloadSessionHasRemainingWork(
          runningCount: overlay.runningCount,
          waitingCount: overlay.waitingCount,
        ),
        isTrue,
      );
      expect(
        shouldFinishDownloadSessionOverlay(
          runningCount: overlay.runningCount,
          waitingCount: overlay.waitingCount,
        ),
        isFalse,
      );
    });

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

    test('Hive lastProgress is kept for fail/kill/pause', () {
      expect(downloadMetadataProgress(null), 0);
      expect(
        downloadMetadataProgress({kDownloadLastProgressMetadataKey: 0.55}),
        0.55,
      );
      expect(
        downloadMetadataExpectedBytes({
          kDownloadLastExpectedBytesMetadataKey: 9000,
        }),
        9000,
      );
    });

    test('user pause is not a waiter and does not occupy a slot', () {
      final plan = planDownloadQueue(
        maxConcurrent: 1,
        queueOrder: const ['ep6', 'ep7', 'ep8'],
        entries: const [
          DownloadQueueEntry(
            taskId: 'ep6',
            status: TaskStatus.paused,
            timestamp: 1,
            userPaused: true,
          ),
          DownloadQueueEntry(
            taskId: 'ep7',
            status: TaskStatus.enqueued,
            timestamp: 2,
          ),
          DownloadQueueEntry(
            taskId: 'ep8',
            status: TaskStatus.paused,
            timestamp: 3,
            userPaused: true,
          ),
        ],
      );
      expect(plan.occupiedCount, 0);
      expect(plan.waitingFifoIds, ['ep7']);
      expect(plan.idsToPromote, isEmpty);
    });

    test(
      'pause-all does not promote paused rows just because slots are free',
      () {
        final plan = planDownloadQueue(
          maxConcurrent: 1,
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep6',
              status: TaskStatus.paused,
              timestamp: 1,
              userPaused: true,
            ),
            DownloadQueueEntry(
              taskId: 'ep7',
              status: TaskStatus.paused,
              timestamp: 2,
              userPaused: true,
            ),
          ],
        );
        expect(plan.occupiedCount, 0);
        expect(plan.idsToPromote, isEmpty);
        expect(plan.waitingFifoIds, isEmpty);
      },
    );

    test('complete skips user-paused and starts the first unpaused waiter', () {
      final plan = planDownloadQueue(
        maxConcurrent: 1,
        queueOrder: const ['ep6', 'ep7', 'ep8'],
        entries: const [
          DownloadQueueEntry(
            taskId: 'ep6',
            status: TaskStatus.complete,
            timestamp: 1,
          ),
          DownloadQueueEntry(
            taskId: 'ep7',
            status: TaskStatus.paused,
            timestamp: 2,
            userPaused: true,
          ),
          DownloadQueueEntry(
            taskId: 'ep8',
            status: TaskStatus.enqueued,
            timestamp: 3,
          ),
        ],
      );
      expect(plan.occupiedCount, 0);
      expect(plan.waitingFifoIds, ['ep8']);
      expect(plan.idsToPromote, isEmpty);
      expect(
        idsToStartAfterParkedFailure(
          maxConcurrent: 1,
          queueOrder: const ['ep6', 'ep7', 'ep8'],
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep7',
              status: TaskStatus.paused,
              timestamp: 2,
              userPaused: true,
            ),
            DownloadQueueEntry(
              taskId: 'ep8',
              status: TaskStatus.enqueued,
              timestamp: 3,
            ),
          ],
        ),
        ['ep8'],
      );
    });

    test(
      'user resume while a slot is occupied waits and restacks later HQ waiters',
      () {
        final plan = planUserResumeQueue(
          resumedId: 'ep7',
          maxConcurrent: 1,
          queueOrder: const ['ep6', 'ep7', 'ep8'],
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep6',
              status: TaskStatus.running,
              timestamp: 1,
            ),
            DownloadQueueEntry(
              taskId: 'ep7',
              status: TaskStatus.paused,
              timestamp: 2,
              userPaused: true,
            ),
            DownloadQueueEntry(
              taskId: 'ep8',
              status: TaskStatus.enqueued,
              timestamp: 3,
            ),
          ],
        );
        expect(plan.startNow, isFalse);
        expect(plan.occupiedCount, 1);
        expect(plan.waitingFifoIds, ['ep7', 'ep8']);
        expect(plan.earlierWaiterIds, isEmpty);
        expect(plan.waitersToRestack, ['ep8']);
        expect(
          shouldStartImmediatelyAfterUserResume(
            resumedId: 'ep7',
            occupyingCount: 1,
            waitingFifoIdsIncludingResumed: plan.waitingFifoIds,
            maxConcurrent: 1,
          ),
          isFalse,
        );
      },
    );

    test('pause-all then play starts that episode immediately', () {
      final plan = planUserResumeQueue(
        resumedId: 'ep6',
        maxConcurrent: 1,
        queueOrder: const ['ep6', 'ep7'],
        entries: const [
          DownloadQueueEntry(
            taskId: 'ep6',
            status: TaskStatus.paused,
            timestamp: 1,
            userPaused: true,
          ),
          DownloadQueueEntry(
            taskId: 'ep7',
            status: TaskStatus.paused,
            timestamp: 2,
            userPaused: true,
          ),
        ],
      );
      expect(plan.startNow, isTrue);
      expect(plan.occupiedCount, 0);
      expect(plan.waitingFifoIds, ['ep6']);
      expect(plan.waitersToRestack, isEmpty);
    });

    test(
      'resume with a free slot and first in FIFO starts now and restacks later waiters',
      () {
        final plan = planUserResumeQueue(
          resumedId: 'ep7',
          maxConcurrent: 1,
          queueOrder: const ['ep7', 'ep8'],
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep7',
              status: TaskStatus.paused,
              timestamp: 1,
              userPaused: true,
            ),
            DownloadQueueEntry(
              taskId: 'ep8',
              status: TaskStatus.enqueued,
              timestamp: 2,
            ),
          ],
        );
        expect(plan.startNow, isTrue);
        expect(plan.waitingFifoIds, ['ep7', 'ep8']);
        expect(plan.waitersToRestack, ['ep8']);
      },
    );

    test(
      'resume keeps original FIFO place ahead of later leftover waiters',
      () {
        final plan = planUserResumeQueue(
          resumedId: 'ep7',
          maxConcurrent: 1,
          queueOrder: const ['ep6', 'ep7', 'ep8'],
          entries: const [
            DownloadQueueEntry(
              taskId: 'ep6',
              status: TaskStatus.running,
              timestamp: 1,
            ),
            DownloadQueueEntry(
              taskId: 'ep7',
              status: TaskStatus.paused,
              timestamp: 2,
              userPaused: true,
            ),
            DownloadQueueEntry(
              taskId: 'ep8',
              status: TaskStatus.paused,
              timestamp: 3,
              queueWaiting: true,
            ),
          ],
        );
        expect(plan.startNow, isFalse);
        expect(plan.waitingFifoIds, ['ep7', 'ep8']);
        expect(plan.waitersToRestack, ['ep8']);
      },
    );

    test('failure-parked is not a waiter when resuming another episode', () {
      final plan = planUserResumeQueue(
        resumedId: 'ep7',
        maxConcurrent: 1,
        queueOrder: const ['ep6', 'ep7', 'ep8'],
        entries: const [
          DownloadQueueEntry(
            taskId: 'ep6',
            status: TaskStatus.running,
            timestamp: 1,
          ),
          DownloadQueueEntry(
            taskId: 'ep7',
            status: TaskStatus.paused,
            timestamp: 2,
            userPaused: true,
          ),
          DownloadQueueEntry(
            taskId: 'ep8',
            status: TaskStatus.paused,
            timestamp: 3,
          ),
        ],
      );
      expect(plan.startNow, isFalse);
      expect(plan.waitingFifoIds, ['ep7']);
      expect(plan.waitersToRestack, isEmpty);
    });

    test('earlier leftover waiters start before a later resumed episode', () {
      final plan = planUserResumeQueue(
        resumedId: 'ep8',
        maxConcurrent: 1,
        queueOrder: const ['ep6', 'ep7', 'ep8'],
        entries: const [
          DownloadQueueEntry(
            taskId: 'ep7',
            status: TaskStatus.paused,
            timestamp: 2,
            queueWaiting: true,
          ),
          DownloadQueueEntry(
            taskId: 'ep8',
            status: TaskStatus.paused,
            timestamp: 3,
            userPaused: true,
          ),
        ],
      );
      expect(plan.startNow, isFalse);
      expect(plan.waitingFifoIds, ['ep7', 'ep8']);
      expect(plan.earlierWaiterIds, ['ep7']);
      expect(plan.waitersToRestack, isEmpty);
    });

    test(
      'kill recovery pauses a user-paused native leftover, never cancels',
      () {
        expect(
          shouldNativePauseAfterUserPause(
            userPaused: true,
            stillInNativeQueue: true,
          ),
          isTrue,
        );
        expect(
          shouldNativePauseAfterUserPause(
            userPaused: true,
            stillInNativeQueue: false,
          ),
          isFalse,
        );
        expect(
          shouldNativePauseAfterUserPause(
            userPaused: false,
            stillInNativeQueue: true,
          ),
          isFalse,
        );
        expect(
          shouldCancelNativeAfterUserPause(
            userPaused: true,
            stillInNativeQueue: true,
          ),
          isFalse,
        );
      },
    );
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

    test(
      'download notification prefs default on and persist toggles',
      () async {
        final storage = MemoryStorageService();
        final repository = SettingsRepository(storage);

        expect(
          repository.getDownloadNotificationPrefs(),
          DownloadNotificationPrefs.enabled,
        );
        await repository.setDownloadNotificationPrefs(
          const DownloadNotificationPrefs(running: false, canceled: false),
        );
        expect(
          repository.getDownloadNotificationPrefs(),
          const DownloadNotificationPrefs(running: false, canceled: false),
        );
        expect(
          downloadNotificationIfEnabled(
            enabled: false,
            title: '{displayName}',
            body: kDownloadCompleteNotificationBody,
          ),
          isNull,
        );
        expect(
          downloadNotificationIfEnabled(
            enabled: true,
            title: '{displayName}',
            body: kDownloadCompleteNotificationBody,
          )?.body,
          kDownloadCompleteNotificationBody,
        );
        expect(
          shouldClearDownloadNotificationConfigs(
            DownloadNotificationPrefs.disabled,
          ),
          isTrue,
        );
        expect(
          shouldClearDownloadNotificationConfigs(
            DownloadNotificationPrefs.enabled,
          ),
          isFalse,
        );
      },
    );
  });
}
