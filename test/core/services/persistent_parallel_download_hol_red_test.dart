import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DM-13 slow host enqueue does not block another host promotion', () async {
    final directory = await Directory.systemTemp.createTemp('parallel-hol-');
    final slowGate = Completer<void>();
    final records = <String, TaskRecord>{};
    final startsByHost = <String, List<DownloadTask>>{
      'slow.example': <DownloadTask>[],
      'fast.example': <DownloadTask>[],
    };

    late final PersistentParallelDownload coordinator;
    coordinator = PersistentParallelDownload(
      startPart: (task, progress, size) async {
        final host = Uri.parse(task.url).host;
        startsByHost.putIfAbsent(host, () => <DownloadTask>[]).add(task);
        if (host == 'slow.example' && startsByHost[host]!.length > 1) {
          await slowGate.future;
        }
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
      livePartIds: () async => <String>{},
      recoveryDelay: const Duration(seconds: 5),
      diskProgressPollInterval: const Duration(seconds: 5),
    );

    addTearDown(() async {
      if (!slowGate.isCompleted) slowGate.complete();
      await coordinator.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    ParallelDownloadTask parent(String id, String host) => ParallelDownloadTask(
      taskId: id,
      url: 'https://$host/video',
      filename: '$id.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 5,
      allowPause: true,
    );

    final slow = parent('slow-parent', 'slow.example');
    final fast = parent('fast-parent', 'fast.example');

    expect(await coordinator.start(slow, 100), isTrue);
    expect(await coordinator.start(fast, 100), isTrue);
    expect(startsByHost['slow.example'], hasLength(1));
    expect(startsByHost['fast.example'], hasLength(1));

    final slowFirst = startsByHost['slow.example']!.single;
    final fastFirst = startsByHost['fast.example']!.single;

    // Acknowledge both initial slow-start connections in the same event-loop
    // turn. Promotion is then owned by the global pump. The second slow-host
    // enqueue deliberately never settles until the gate opens.
    coordinator.handleUpdate(TaskStatusUpdate(slowFirst, TaskStatus.running));
    coordinator.handleUpdate(TaskStatusUpdate(fastFirst, TaskStatus.running));

    final fastPromoted = await Future.any(<Future<bool>>[
      () async {
        for (var i = 0; i < 40; i++) {
          if (startsByHost['fast.example']!.length > 1) return true;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        return false;
      }(),
      Future<bool>.delayed(const Duration(milliseconds: 250), () => false),
    ]);

    // Always release the intentionally stalled enqueue so teardown itself
    // cannot hang on the known bug.
    if (!slowGate.isCompleted) slowGate.complete();

    expect(
      fastPromoted,
      isTrue,
      reason:
          'a pending/slow enqueue for one origin must not head-of-line block '
          'promotion of a healthy origin',
    );
  });
}
