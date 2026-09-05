from pathlib import Path

p = Path('test/core/services/download_concurrency_test.dart')
text = p.read_text(encoding='utf-8')


def replace_once(old: str, new: str, label: str) -> None:
    global text
    if old not in text:
        raise RuntimeError(f'missing test marker: {label}')
    text = text.replace(old, new, 1)

# With plugin HoldingQueue disabled, `enqueued` is a short starting/reserved
# state. Persistent waiters are paused records with queueWaiting=true.
replace_once(
    "'native snapshot waiters are HQ enqueued + leftover parked, never user-paused'",
    "'native snapshot contains app-owned waiters, never starting or user-paused rows'",
    'native snapshot title',
)
replace_once(
    """        expect(
          isNativeWaitingSnapshotWaiter(
            status: TaskStatus.enqueued,
            queueWaiting: false,
            userPaused: false,
          ),
          isTrue,
        );""",
    """        expect(
          isNativeWaitingSnapshotWaiter(
            status: TaskStatus.enqueued,
            queueWaiting: false,
            userPaused: false,
          ),
          isFalse,
        );""",
    'starting row is not native waiter snapshot',
)

replace_once(
    "'iOS concurrency=1, two episodes: waiter is enqueued, overlay only when running'",
    "'iOS concurrency=1, two episodes: app waiter promotes only after slot frees'",
    'ios queue title',
)
replace_once(
    """            DownloadQueueEntry(
              taskId: 'ep2',
              status: TaskStatus.enqueued,
              timestamp: 2,
            ),""",
    """            DownloadQueueEntry(
              taskId: 'ep2',
              status: TaskStatus.paused,
              timestamp: 2,
              queueWaiting: true,
            ),""",
    'ios waiter while ep1 runs',
)
replace_once(
    """            DownloadQueueEntry(
              taskId: 'ep2',
              status: TaskStatus.enqueued,
              timestamp: 2,
            ),""",
    """            DownloadQueueEntry(
              taskId: 'ep2',
              status: TaskStatus.paused,
              timestamp: 2,
              queueWaiting: true,
            ),""",
    'ios waiter after ep1 completes',
)
replace_once(
    """        expect(afterEp1Finishes.idsToPromote, isEmpty);
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
        );""",
    """        expect(afterEp1Finishes.idsToPromote, ['ep2']);
        expect(
          shouldAttachToLiveNativeTask(
            taskId: 'ep2',
            trackingUrl: 'https://cdn.test/ep2',
            live: const [],
          ),
          isFalse,
        );""",
    'ios promotion after slot frees',
)

# Failed/paused rows release the slot; app-owned waiters are queueWaiting.
replace_once(
    """        DownloadQueueEntry(
          taskId: 'ep7',
          status: TaskStatus.enqueued,
          timestamp: 2,
        ),
        DownloadQueueEntry(
          taskId: 'ep9',
          status: TaskStatus.enqueued,
          timestamp: 3,
        ),""",
    """        DownloadQueueEntry(
          taskId: 'ep7',
          status: TaskStatus.paused,
          timestamp: 2,
          queueWaiting: true,
        ),
        DownloadQueueEntry(
          taskId: 'ep9',
          status: TaskStatus.paused,
          timestamp: 3,
          queueWaiting: true,
        ),""",
    'failed episode waiters',
)

replace_once(
    """          DownloadQueueEntry(
            taskId: 'ep7',
            status: TaskStatus.enqueued,
            timestamp: 2,
          ),""",
    """          DownloadQueueEntry(
            taskId: 'ep7',
            status: TaskStatus.paused,
            timestamp: 2,
            queueWaiting: true,
          ),""",
    'user pause test waiter',
)
replace_once(
    """      expect(plan.idsToPromote, isEmpty);
    });

    test(
      'pause-all does not promote paused rows just because slots are free',""",
    """      expect(plan.idsToPromote, ['ep7']);
    });

    test(
      'pause-all does not promote paused rows just because slots are free',""",
    'user pause promotion expectation',
)

replace_once(
    """          DownloadQueueEntry(
            taskId: 'ep8',
            status: TaskStatus.enqueued,
            timestamp: 3,
          ),""",
    """          DownloadQueueEntry(
            taskId: 'ep8',
            status: TaskStatus.paused,
            timestamp: 3,
            queueWaiting: true,
          ),""",
    'complete test waiter',
)
replace_once(
    """      expect(plan.idsToPromote, isEmpty);
      expect(
        idsToStartAfterParkedFailure(""",
    """      expect(plan.idsToPromote, ['ep8']);
      expect(
        idsToStartAfterParkedFailure(""",
    'complete promotion expectation',
)
replace_once(
    """            DownloadQueueEntry(
              taskId: 'ep8',
              status: TaskStatus.enqueued,
              timestamp: 3,
            ),""",
    """            DownloadQueueEntry(
              taskId: 'ep8',
              status: TaskStatus.paused,
              timestamp: 3,
              queueWaiting: true,
            ),""",
    'complete helper waiter',
)

replace_once(
    "'user resume while a slot is occupied waits and restacks later HQ waiters'",
    "'user resume while a slot is occupied waits behind the active transfer'",
    'resume occupied title',
)
replace_once(
    """            DownloadQueueEntry(
              taskId: 'ep8',
              status: TaskStatus.enqueued,
              timestamp: 3,
            ),""",
    """            DownloadQueueEntry(
              taskId: 'ep8',
              status: TaskStatus.paused,
              timestamp: 3,
              queueWaiting: true,
            ),""",
    'resume occupied later waiter',
)

replace_once(
    "'resume with a free slot and first in FIFO starts now and restacks later waiters'",
    "'resume with a free slot and first in FIFO starts now ahead of later waiters'",
    'resume free title',
)
replace_once(
    """          DownloadQueueEntry(
            taskId: 'ep8',
            status: TaskStatus.enqueued,
            timestamp: 2,
          ),""",
    """          DownloadQueueEntry(
            taskId: 'ep8',
            status: TaskStatus.paused,
            timestamp: 2,
            queueWaiting: true,
          ),""",
    'resume free later waiter',
)

p.write_text(text, encoding='utf-8')
print('Aligned legacy queue tests with app-owned waiter representation')
