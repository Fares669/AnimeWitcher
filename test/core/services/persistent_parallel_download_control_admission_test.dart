import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('uncertain cancel ACK keeps admission fenced until explicit resume', () async {
    final directory = await Directory.systemTemp.createTemp('parallel-uncertain-cancel-');
    final records = <String, TaskRecord>{};
    final starts = <DownloadTask>[];
    final parent = ParallelDownloadTask(
      taskId: 'uncertain-cancel', url: 'https://example.test/video',
      filename: 'video.mp4', directory: directory.path,
      baseDirectory: BaseDirectory.root, chunks: 2, allowPause: true,
    );
    final coordinator = PersistentParallelDownload(
      startPart: (task, progress, size) async { starts.add(task); return true; },
      pausePart: (_) async {},
      cancelParts: (_) async => throw TimeoutException('native cancel ACK unknown'),
      saveRecord: (record) async { records[record.taskId] = record; },
      recordForId: (id) async => records[id],
      onUpdate: (_) {}, onPartProgress: (_, _, _) {},
      livePartIds: () async => starts.map((task) => task.taskId).toSet(),
    );
    try {
      expect(await coordinator.start(parent, 8), isTrue);
      await expectLater(coordinator.cancel(parent), throwsA(isA<TimeoutException>()));
      expect(coordinator.nativeBackgroundPlans(), isEmpty,
        reason: 'unknown cancellation cannot grant another native launch');
      coordinator.handleUpdate(TaskStatusUpdate(starts.single, TaskStatus.running));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(starts, hasLength(1));
    } finally {
      await coordinator.dispose();
      await directory.delete(recursive: true);
    }
  });

  for (final cancel in [false, true]) {
    test('${cancel ? 'cancel' : 'pause'} fences a range awaiting its pre-enqueue record', () async {
      final directory = await Directory.systemTemp.createTemp('parallel-control-admission-');
      final recordEntered = Completer<void>();
      final recordReleased = Completer<void>();
      final starts = <DownloadTask>[];
      final records = <String, TaskRecord>{};
      final parent = ParallelDownloadTask(
        taskId: 'control-admission', url: 'https://example.test/video',
        filename: 'video.mp4', directory: directory.path,
        baseDirectory: BaseDirectory.root, chunks: 2, allowPause: true,
      );
      final coordinator = PersistentParallelDownload(
        startPart: (task, progress, size) async {
          starts.add(task);
          return true;
        },
        pausePart: (_) async {},
        cancelParts: (_) async {},
        saveRecord: (record) async { records[record.taskId] = record; },
        recordForId: (id) async {
          if (id.endsWith('.part.1')) {
            if (!recordEntered.isCompleted) recordEntered.complete();
            await recordReleased.future;
          }
          return records[id];
        },
        onUpdate: (_) {}, onPartProgress: (_, _, _) {},
        livePartIds: () async => starts.map((task) => task.taskId).toSet(),
        shouldDrainPartOnPause: (_) => true,
      );
      try {
        expect(await coordinator.start(parent, 8), isTrue);
        expect(starts, hasLength(1));
        coordinator.handleUpdate(TaskStatusUpdate(starts.single, TaskStatus.running));
        await recordEntered.future.timeout(const Duration(seconds: 2));
        final control = cancel
            ? coordinator.cancel(parent)
            : coordinator.pause(parent, preserveLiveParts: true);
        // Both controls set the synchronous intent fence before their first
        // serialized action can enter behind the blocked pump.
        await Future<void>.delayed(Duration.zero);
        recordReleased.complete();
        await control;
        expect(starts, hasLength(1),
          reason: 'pre-enqueue IO must recheck user intent before granting a native writer');
      } finally {
        if (!recordReleased.isCompleted) recordReleased.complete();
        await coordinator.dispose();
        await directory.delete(recursive: true);
      }
    });
  }
}
