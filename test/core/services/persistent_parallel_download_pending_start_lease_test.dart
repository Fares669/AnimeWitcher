import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mib = 1024 * 1024;

  Future<void> waitUntil(bool Function() predicate) async {
    for (var i = 0; i < 100; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting for pending-start lease condition');
  }

  Future<({
    Directory directory,
    ParallelDownloadTask parent,
    PersistentParallelDownload coordinator,
    List<DownloadTask> starts,
  })>
  buildHarness({
    required String id,
    required Future<Set<String>> Function() livePartIds,
    Duration lease = const Duration(milliseconds: 40),
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'parallel-pending-start-lease-',
    );
    final starts = <DownloadTask>[];
    final records = <String, TaskRecord>{};
    final parent = ParallelDownloadTask(
      taskId: id,
      url: 'https://cdn.example.test/$id.mp4',
      filename: '$id.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 2,
      allowPause: true,
    );
    final coordinator = PersistentParallelDownload(
      startPart: (task, progress, size) async {
        starts.add(task);
        return true;
      },
      pausePart: (_) async {},
      cancelParts: (_) async {},
      saveRecord: (record) async {
        records[record.task.taskId] = record;
      },
      recordForId: (taskId) async => records[taskId],
      onUpdate: (_) {},
      onPartProgress: (_, _, _) {},
      livePartIds: livePartIds,
      recoveryDelay: const Duration(milliseconds: 10),
      pendingStartLeaseDelay: lease,
      maxActiveConnections: 2,
    );
    return (
      directory: directory,
      parent: parent,
      coordinator: coordinator,
      starts: starts,
    );
  }

  Future<void> disposeHarness(
    ({
      Directory directory,
      ParallelDownloadTask parent,
      PersistentParallelDownload coordinator,
      List<DownloadTask> starts,
    })
    harness,
  ) async {
    await harness.coordinator.dispose();
    if (await harness.directory.exists()) {
      await harness.directory.delete(recursive: true);
    }
  }

  test(
    'accepted multipart start with no callback releases stale pending reservation',
    () async {
      final harness = await buildHarness(
        id: 'pending-start-episode',
        livePartIds: () async => <String>{},
      );
      try {
        expect(await harness.coordinator.start(harness.parent, 2 * mib), isTrue);
        expect(harness.starts, hasLength(1));
        final first = harness.starts.single;

        // Another range may use the freed slot while this range observes its
        // recovery backoff, but the original immutable Range must itself retry
        // with a new attempt generation.
        await waitUntil(
          () =>
              harness.starts
                  .where((task) => task.taskId == first.taskId)
                  .length >=
              2,
        );

        final retriedFirstRange = harness.starts
            .where((task) => task.taskId == first.taskId)
            .skip(1)
            .first;
        expect(retriedFirstRange.metaData, isNot(first.metaData));
        expect(harness.coordinator.isActive(harness.parent.taskId), isTrue);
      } finally {
        await disposeHarness(harness);
      }
    },
  );

  test('proven runtime ownership adopts pending start without duplicate writer', () async {
    final live = <String>{};
    final harness = await buildHarness(
      id: 'pending-start-owned',
      livePartIds: () async => Set<String>.from(live),
    );
    try {
      expect(await harness.coordinator.start(harness.parent, 2 * mib), isTrue);
      final first = harness.starts.single;
      live.add(first.taskId);

      // Lease expiry should convert the reservation into verified ownership.
      // Slow-start may then launch the sibling, but must never relaunch first.
      await waitUntil(() => harness.starts.length >= 2);
      expect(
        harness.starts.where((task) => task.taskId == first.taskId),
        hasLength(1),
      );
    } finally {
      await disposeHarness(harness);
    }
  });

  test('unknown runtime ownership keeps lease and never creates second writer', () async {
    final harness = await buildHarness(
      id: 'pending-start-unknown',
      livePartIds: () async => throw StateError('liveness unavailable'),
    );
    try {
      expect(await harness.coordinator.start(harness.parent, 2 * mib), isTrue);
      final first = harness.starts.single;
      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(
        harness.starts.where((task) => task.taskId == first.taskId),
        hasLength(1),
      );
      expect(harness.starts, hasLength(1));
      expect(harness.coordinator.isActive(harness.parent.taskId), isTrue);
    } finally {
      await disposeHarness(harness);
    }
  });

  test('reconcile during pending-start lease adopts real native ownership', () async {
    final harness = await buildHarness(
      id: 'pending-start-reconcile',
      livePartIds: () async => <String>{},
      lease: const Duration(milliseconds: 200),
    );
    try {
      expect(await harness.coordinator.start(harness.parent, 2 * mib), isTrue);
      final first = harness.starts.single;

      await harness.coordinator.reconcile(() async => <String>{first.taskId});
      await waitUntil(() => harness.starts.length >= 2);

      expect(
        harness.starts.where((task) => task.taskId == first.taskId),
        hasLength(1),
      );
    } finally {
      await disposeHarness(harness);
    }
  });

  test('pause during pending-start lease cancels lease recovery', () async {
    final harness = await buildHarness(
      id: 'pending-start-pause',
      livePartIds: () async => <String>{},
      lease: const Duration(milliseconds: 80),
    );
    try {
      expect(await harness.coordinator.start(harness.parent, 2 * mib), isTrue);
      expect(harness.starts, hasLength(1));

      expect(await harness.coordinator.pause(harness.parent), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(harness.starts, hasLength(1));
      expect(harness.coordinator.isActive(harness.parent.taskId), isFalse);
    } finally {
      await disposeHarness(harness);
    }
  });
}
