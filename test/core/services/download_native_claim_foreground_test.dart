import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitUntil(bool Function() predicate) async {
    for (var i = 0; i < 100; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting for multipart claim handoff');
  }

  test('foreground return releases unclaimed native offers back to Dart pump', () async {
    final directory = await Directory.systemTemp.createTemp(
      'parallel-foreground-claims-',
    );
    final records = <String, TaskRecord>{};
    final starts = <DownloadTask>[];
    final parent = ParallelDownloadTask(
      taskId: 'claim-parent',
      url: 'https://example.com/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 5,
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
      recordForId: (id) async => records[id],
      onUpdate: (_) {},
      onPartProgress: (_, _, _) {},
      livePartIds: () async => starts.map((task) => task.taskId).toSet(),
      maxActiveConnections: 5,
    );

    try {
      expect(await coordinator.start(parent, 25), isTrue);
      expect(starts, hasLength(1));
      final first = starts.single;

      // A background snapshot offers the untouched sibling ranges to Swift.
      // If the app returns to foreground before Swift claims them, Dart must be
      // able to withdraw those offers and continue slow-start itself.
      final plans = coordinator.nativeBackgroundPlans();
      expect(plans, isNotEmpty);
      expect(plans.single.candidates, isNotEmpty);

      coordinator.handleUpdate(TaskStatusUpdate(first, TaskStatus.running));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        starts,
        hasLength(1),
        reason: 'outstanding native offers deliberately fence Dart ownership',
      );

      coordinator.releaseNativeBackgroundOffers();
      await waitUntil(() => starts.length > 1);
      expect(starts.map((task) => task.taskId).toSet().length, greaterThan(1));
    } finally {
      await coordinator.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });

  test('sampling native offers does not rewrite an unchanged checkpoint', () async {
    final directory = await Directory.systemTemp.createTemp(
      'parallel-idle-claims-',
    );
    final records = <String, TaskRecord>{};
    final starts = <DownloadTask>[];
    final parent = ParallelDownloadTask(
      taskId: 'idle-claim-parent',
      url: 'https://example.com/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 5,
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
      recordForId: (id) async => records[id],
      onUpdate: (_) {},
      onPartProgress: (_, _, _) {},
      livePartIds: () async => starts.map((task) => task.taskId).toSet(),
      maxActiveConnections: 1,
    );

    try {
      expect(await coordinator.start(parent, 25), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final manifest = File('${await parent.filePath()}.parts/manifest.json');
      final before = jsonDecode(await manifest.readAsString()) as Map;

      for (var sample = 0; sample < 5; sample++) {
        expect(coordinator.nativeBackgroundPlans().single.candidates, isNotEmpty);
        coordinator.releaseNativeBackgroundOffers();
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final after = jsonDecode(await manifest.readAsString()) as Map;
      expect(
        after['checkpointSequence'],
        before['checkpointSequence'],
        reason: 'no scheduler was blocked by the short-lived native offers',
      );
      expect(starts, hasLength(1));
    } finally {
      await coordinator.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });
}
