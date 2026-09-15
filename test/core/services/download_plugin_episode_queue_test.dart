import 'dart:io';

import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('eight plugin chunks still reserve one logical episode slot', () {
    ParallelDownloadTask parent(String id) => ParallelDownloadTask(
      taskId: id,
      url: 'https://example.test/$id.mp4',
      filename: '$id.mp4',
      group: kLogicalDownloadGroup,
      chunks: 8,
    );

    final first = parent('episode-1');
    final second = parent('episode-2');
    final third = parent('episode-3');

    expect(downloadTaskPartCount(first), 8);
    expect(isLogicalEpisodeDownloadTask(first), isTrue);
    expect(isLogicalEpisodeDownloadTask(second), isTrue);
    expect(isLogicalEpisodeDownloadTask(third), isTrue);

    final plan = planDownloadQueue(
      maxConcurrent: 2,
      entries: const <DownloadQueueEntry>[
        DownloadQueueEntry(
          taskId: 'episode-1',
          status: TaskStatus.running,
          timestamp: 1,
        ),
        DownloadQueueEntry(
          taskId: 'episode-2',
          status: TaskStatus.running,
          timestamp: 2,
        ),
        DownloadQueueEntry(
          taskId: 'episode-3',
          status: TaskStatus.paused,
          timestamp: 3,
          queueWaiting: true,
        ),
      ],
      queueOrder: const <String>['episode-1', 'episode-2', 'episode-3'],
    );

    expect(plan.occupiedCount, 2);
    expect(plan.freeSlots, 0);
    expect(plan.waitingFifoIds, const <String>['episode-3']);
    expect(plan.idsToPromote, isEmpty);
  });

  test('plugin and legacy child records are never logical queue episodes', () {
    final pluginChild = DownloadTask(
      taskId: 'plugin-child',
      url: 'https://example.test/chunk',
      filename: 'chunk',
      group: FileDownloader.chunkGroup,
    );
    final legacyChild = DownloadTask(
      taskId: 'legacy-child',
      url: 'https://example.test/part',
      filename: 'part',
      group: kPersistentDownloadChunkGroup,
    );

    expect(isInternalDownloaderChunk(pluginChild), isTrue);
    expect(isInternalDownloaderChunk(legacyChild), isTrue);
    expect(isLogicalEpisodeDownloadTask(pluginChild), isFalse);
    expect(isLogicalEpisodeDownloadTask(legacyChild), isFalse);
  });

  test('service queue accounting filters child rows before slot decisions', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final occupiedStart = source.indexOf(
      'Future<int> _occupiedSlotCount(List<TaskRecord> records) async',
    );
    final queueStart = source.indexOf(
      'Future<List<DownloadQueueEntry>> _queueEntries(',
      occupiedStart,
    );
    final syncStart = source.indexOf(
      'Future<void> _syncQueueToCapUnlocked()',
      queueStart,
    );

    expect(occupiedStart, greaterThanOrEqualTo(0));
    expect(queueStart, greaterThan(occupiedStart));
    expect(syncStart, greaterThan(queueStart));

    final occupiedBody = source.substring(occupiedStart, queueStart);
    final queueBody = source.substring(queueStart, syncStart);
    expect(
      occupiedBody,
      contains('if (!isLogicalEpisodeDownloadTask(record.task)) continue;'),
    );
    expect(
      queueBody,
      contains('if (!isLogicalEpisodeDownloadTask(record.task)) continue;'),
    );
    expect(occupiedBody, isNot(contains('downloadTaskPartCount(')));
    expect(queueBody, isNot(contains('downloadTaskPartCount(')));
  });

  test('native HoldingQueue stays disabled so chunks cannot consume episode cap', () {
    expect(
      downloadHoldingQueueGlobalConfig(2),
      <(String, dynamic)>[(Config.holdingQueue, false)],
    );
  });
}
