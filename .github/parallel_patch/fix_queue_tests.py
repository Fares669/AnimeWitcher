from pathlib import Path

p = Path('test/core/services/download_concurrency_test.dart')
text = p.read_text(encoding='utf-8')


def rewrite_test(title: str, replacements: list[tuple[str, str, int]], new_title: str | None = None) -> None:
    global text
    title_index = text.find(title)
    if title_index < 0:
        raise RuntimeError(f'missing test title: {title}')
    start = text.rfind('    test(', 0, title_index)
    if start < 0:
        raise RuntimeError(f'missing test start: {title}')
    end = text.find('\n    test(', title_index + len(title))
    if end < 0:
        end = len(text)
    block = text[start:end]
    for old, new, expected_count in replacements:
        count = block.count(old)
        if count != expected_count:
            raise RuntimeError(
                f'{title}: expected {expected_count} marker(s), found {count}: {old[:80]!r}'
            )
        block = block.replace(old, new, expected_count)
    if new_title is not None:
        block = block.replace(title, new_title, 1)
    text = text[:start] + block + text[end:]


# With plugin HoldingQueue disabled, `enqueued` is a short starting/reserved
# state. Persistent waiters are paused records with queueWaiting=true.
rewrite_test(
    "'native snapshot waiters are HQ enqueued + leftover parked, never user-paused'",
    [
        (
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
            1,
        ),
    ],
    new_title="'native snapshot contains app-owned waiters, never starting or user-paused rows'",
)

rewrite_test(
    "'iOS concurrency=1, two episodes: waiter is enqueued, overlay only when running'",
    [
        (
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
            2,
        ),
        (
            "expect(afterEp1Finishes.idsToPromote, isEmpty);",
            "expect(afterEp1Finishes.idsToPromote, ['ep2']);",
            1,
        ),
        (
            """            live: const [
              LiveNativeDownload(
                taskId: 'ep2',
                trackingUrl: 'https://cdn.test/ep2',
              ),
            ],""",
            """            live: const [],""",
            1,
        ),
        (
            """          isTrue,
        );
        expect(shouldStartDownloadLiveActivity(TaskStatus.running), isTrue);""",
            """          isFalse,
        );
        expect(shouldStartDownloadLiveActivity(TaskStatus.running), isTrue);""",
            1,
        ),
    ],
    new_title="'iOS concurrency=1, two episodes: app waiter promotes only after slot frees'",
)

rewrite_test(
    "'a failed episode parks paused and the next waiter starts'",
    [
        (
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
            1,
        ),
    ],
)

rewrite_test(
    "'user pause is not a waiter and does not occupy a slot'",
    [
        (
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
            1,
        ),
        ("expect(plan.idsToPromote, isEmpty);", "expect(plan.idsToPromote, ['ep7']);", 1),
    ],
)

rewrite_test(
    "'complete skips user-paused and starts the first unpaused waiter'",
    [
        (
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
            1,
        ),
        (
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
            1,
        ),
        ("expect(plan.idsToPromote, isEmpty);", "expect(plan.idsToPromote, ['ep8']);", 1),
    ],
)

rewrite_test(
    "'user resume while a slot is occupied waits and restacks later HQ waiters'",
    [
        (
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
            1,
        ),
    ],
    new_title="'user resume while a slot is occupied waits behind the active transfer'",
)

rewrite_test(
    "'resume with a free slot and first in FIFO starts now and restacks later waiters'",
    [
        (
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
            1,
        ),
    ],
    new_title="'resume with a free slot and first in FIFO starts now ahead of later waiters'",
)

p.write_text(text, encoding='utf-8')
print('Aligned legacy queue tests with app-owned waiter representation')
