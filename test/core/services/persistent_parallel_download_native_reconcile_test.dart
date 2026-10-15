import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/parallel_download_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final preserve in [true, false]) {
    test(
      'pause accounts for native-only owners with drain $preserve',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'native-pause-',
        );
        final parent = ParallelDownloadTask(
          taskId: 'aw_v2_native_pause_g1',
          url: 'https://example.invalid/video',
          filename: 'video.mp4',
          directory: directory.path,
          baseDirectory: BaseDirectory.root,
          chunks: 2,
          allowPause: true,
        );
        final records = <String, TaskRecord>{};
        final live = <String>{};
        final paused = <String>[];
        final coordinator = PersistentParallelDownload(
          startPart: (_, _, _) async => true,
          pausePart: (task) async {
            paused.add(task.taskId);
            live.remove(task.taskId);
          },
          cancelParts: (_) async {},
          saveRecord: (record) async {
            records[record.taskId] = record;
          },
          recordForId: (id) async => records[id],
          onUpdate: (_) {},
          onPartProgress: (_, _, _) {},
          livePartIds: () async => live,
          shouldDrainPartOnPause: (_) => true,
          diskProgressPollInterval: const Duration(hours: 1),
        );
        try {
          await coordinator.start(parent, 20);
          final native = coordinator
              .nativeBackgroundPlans()
              .single
              .candidates
              .first
              .task;
          live.add(native.taskId);
          var withdrew = false;
          expect(
            await coordinator.pause(
              parent,
              preserveLiveParts: preserve,
              beforePause: () async {
                expect(
                  coordinator.nativeBackgroundPlans(),
                  isEmpty,
                  reason: 'pause intent fences export before the native withdrawal await',
                );
                withdrew = true;
              },
            ),
            isTrue,
          );
          expect(withdrew, isTrue);
          expect(coordinator.isActive(parent.taskId), isFalse);
          if (preserve) {
            expect(paused, isNot(contains(native.taskId)));
            expect(
              coordinator.activeConnectionCount,
              1,
              reason: 'native-only immutable range must keep its drain lease',
            );
          } else {
            expect(paused, contains(native.taskId));
            expect(coordinator.activeConnectionCount, 0);
          }
        } finally {
          await coordinator.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  for (final acceptSource in [true, false]) {
    test(
      'foreground reconciles native-only parts with source acceptance $acceptSource',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'native-reconcile-',
        );
        final parent = ParallelDownloadTask(
          taskId: 'aw_v2_background_g1',
          url: 'https://example.invalid/video',
          filename: 'video.mp4',
          directory: directory.path,
          baseDirectory: BaseDirectory.root,
          chunks: 2,
          allowPause: true,
        );
        final starts = <DownloadTask>[];
        final records = <String, TaskRecord>{};
        final statuses = <TaskStatus>[];
        final coordinator = PersistentParallelDownload(
          startPart: (task, progress, size) async {
            starts.add(task);
            return true;
          },
          pausePart: (_) async {},
          cancelParts: (_) async {},
          saveRecord: (record) async {
            records[record.taskId] = record;
          },
          recordForId: (id) async => records[id],
          onUpdate: (update) {
            if (update is TaskStatusUpdate) statuses.add(update.status);
          },
          onPartProgress: (_, _, _) {},
          verifyPartSource: acceptSource
              ? verifiedSavedTestRange
              : (_, _, _, _) async => (matches: false, validator: null),
          promoteFile: publishCompletedTestFile,
          livePartIds: () async => <String>{},
          diskProgressPollInterval: const Duration(hours: 1),
        );
        try {
          expect(await coordinator.start(parent, 20), isTrue);
          expect(
            starts,
            hasLength(1),
            reason: 'only the first slow-start range is Dart-launched',
          );
          final plans = coordinator.nativeBackgroundPlans();
          expect(plans.single.candidates, isNotEmpty);
          final manifest = jsonDecode(
            await File('${await parent.filePath()}.parts/manifest.json')
                .readAsString(),
          ) as Map;
          for (final raw in manifest['parts'] as List) {
            final part = raw as Map;
            final task = Task.createFromJson(
              Map<String, dynamic>.from(part['task'] as Map),
            ) as DownloadTask;
            final from = part['from'] as int;
            final to = part['to'] as int;
            await File(await task.filePath()).writeAsBytes(
              List<int>.generate(to - from + 1, (index) => from + index),
              flush: true,
            );
          }
          // Simulates native refill completing all ranges while Flutter received
          // no child callbacks. Some ranges are still unlaunched in Dart state.
          await coordinator.reconcile(() async => <String>{});
          if (acceptSource) {
            expect(statuses, contains(TaskStatus.complete));
            expect(
              await File(await parent.filePath()).readAsBytes(),
              List<int>.generate(20, (i) => i),
            );
            expect(
              starts,
              hasLength(1),
              reason: 'completed native-only ranges must not download again',
            );
          } else {
            expect(statuses, isNot(contains(TaskStatus.complete)));
            expect(
              await File(await parent.filePath()).exists(),
              isFalse,
              reason: 'same-sized files alone are never completion authority',
            );
          }
        } finally {
          await coordinator.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
