import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/parallel_download_fixtures.dart';

Future<bool> settlesSoon(Future<void> work) => Future.any([
  work.then((_) => true),
  Future<bool>.delayed(const Duration(milliseconds: 300), () => false),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native completion cannot re-download a range ahead of package success',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'range-verifier-queue-',
      );
      final verification = Completer<({bool matches, String? validator})>();
      final completed = Completer<void>();
      final starts = <DownloadTask>[];
      var verificationCalls = 0;
      final parent = ParallelDownloadTask(
        taskId: 'aw_v2_verification_queue_g1',
        url: 'https://example.invalid/video',
        filename: 'video.mp4',
        directory: root.path,
        baseDirectory: BaseDirectory.root,
        chunks: 2,
        allowPause: true,
      );
      final coordinator = PersistentParallelDownload(
        startPart: (task, _, _) async {
          starts.add(task);
          return true;
        },
        pausePart: (_) async {},
        cancelParts: (_) async {},
        saveRecord: (record) async {
          if (record.taskId.endsWith('.part.0') &&
              record.status == TaskStatus.complete &&
              !completed.isCompleted) {
            completed.complete();
          }
        },
        recordForId: (_) async => null,
        onUpdate: (_) {},
        onPartProgress: (_, _, _) {},
        verifyPartSource: (_, _, _, _) {
          verificationCalls++;
          return verification.future;
        },
        diskProgressPollInterval: const Duration(hours: 1),
      );
      try {
        expect(await coordinator.start(parent, 20), isTrue);
        final child = starts.single;
        await File(await child.filePath()).writeAsBytes(List.filled(10, 1));
        final bridge = coordinator.handleNativeChunkUpdate(
          parentTaskId: parent.taskId,
          chunkTaskId: child.taskId,
          attemptGeneration: 1,
          writtenBytes: 10,
          expectedBytes: 10,
          completed: true,
        );
        // The native bridge precedes the package's HTTP response evidence.
        await bridge;
        coordinator.handleUpdate(
          TaskStatusUpdate(child, TaskStatus.complete, null, null, {
            'content-range': 'bytes 0-9/20',
            'etag': '"same-resource"',
          }, 206),
        );
        expect(
          await settlesSoon(completed.future),
          isTrue,
          reason: 'the HTTP-complete event must not wait for a fallback network probe',
        );
        expect(
          verificationCalls,
          0,
          reason:
              'fresh validated URLSession bytes must not be downloaded twice',
        );
        await bridge;
      } finally {
        if (!verification.isCompleted) {
          verification.complete((matches: true, validator: null));
        }
        await coordinator.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  for (final action in ['pause', 'cancel']) {
    test(
      'orphan verification does not block $action or relaunch its saved range',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'range-verifier-control-',
        );
        final verification = Completer<({bool matches, String? validator})>();
        final verificationStarted = Completer<void>();
        final parent = ParallelDownloadTask(
          taskId: 'aw_v2_orphan_verification_g1',
          url: 'https://example.invalid/video',
          filename: 'video.mp4',
          directory: root.path,
          baseDirectory: BaseDirectory.root,
          chunks: 2,
          allowPause: true,
        );
        final starts = <DownloadTask>[];
        PersistentParallelDownload makeCoordinator() =>
            PersistentParallelDownload(
              startPart: (task, _, _) async {
                starts.add(task);
                return true;
              },
              pausePart: (_) async {},
              cancelParts: (_) async {},
              saveRecord: (_) async {},
              recordForId: (_) async => null,
              onUpdate: (_) {},
              onPartProgress: (_, _, _) {},
              livePartIds: () async => <String>{},
              verifyPartSource: (_, _, _, _) {
                if (!verificationStarted.isCompleted) {
                  verificationStarted.complete();
                }
                return verification.future;
              },
              promoteFile: publishCompletedTestFile,
              diskProgressPollInterval: const Duration(hours: 1),
            );
        var coordinator = makeCoordinator();
        try {
          await coordinator.start(parent, 20);
          await coordinator.dispose();
          final manifest = jsonDecode(
            await File('${await parent.filePath()}.parts/manifest.json')
                .readAsString(),
          ) as Map;
          for (final raw in manifest['parts'] as List) {
            final task = Task.createFromJson(
              Map<String, dynamic>.from(raw['task'] as Map),
            ) as DownloadTask;
            await File(await task.filePath()).writeAsBytes(List.filled(10, 1));
          }
          starts.clear();
          coordinator = makeCoordinator();
          expect(
            await settlesSoon(coordinator.start(parent, 20).then((_) {})),
            isTrue,
            reason: 'resume should admit recovery without waiting for N remote verifications',
          );
          await verificationStarted.future.timeout(const Duration(seconds: 2));
          expect(
            starts,
            isEmpty,
            reason: 'saved orphan ranges stay fenced while unverified',
          );
          final control = action == 'pause'
              ? coordinator.pause(parent).then((_) {})
              : coordinator.cancel(parent);
          expect(
            await settlesSoon(control),
            isTrue,
            reason: 'a slow origin must not hold the parent control queue',
          );
          verification.complete((matches: true, validator: null));
          await verification.future;
          await coordinator.reconcile(() async => <String>{});
          expect(coordinator.isActive(parent.taskId), isFalse);
          expect(starts, isEmpty);
          expect(
            await File(await parent.filePath()).exists(),
            isFalse,
            reason:
                'late verification cannot publish or revive a stopped parent',
          );
          if (action == 'pause') {
            expect(
              await File('${await parent.filePath()}.parts/0.part').length(),
              10,
            );
          }
        } finally {
          if (!verification.isCompleted) {
            verification.complete((matches: true, validator: null));
          }
          await coordinator.dispose();
          if (await root.exists()) await root.delete(recursive: true);
        }
      },
    );
  }
  test('late native events cannot revive a verifying range and HTTP success cancels its probe', () async {
    final fixture = await SavedRangesFixture.create();
    final probe = Completer<({bool matches, String? validator})>();
    final started = Completer<DownloadTask>();
    final cancelled = Completer<void>();
    final adopted = Completer<void>();
    final starts = <DownloadTask>[];
    var calls = 0;
    final coordinator = fixture.coordinator(
      maxActiveConnections: 1,
      startPart: (task, _, _) async {
        starts.add(task);
        return true;
      },
      verifyPartSource: (task, _, _, _) {
        calls++;
        if (!started.isCompleted) started.complete(task);
        return probe.future;
      },
      cancelPartSourceVerification: (_) {
        if (!cancelled.isCompleted) cancelled.complete();
      },
      saveRecord: (record) async {
        if (record.taskId == fixture.parts.first.taskId &&
            record.status == TaskStatus.complete &&
            !adopted.isCompleted) {
          adopted.complete();
        }
      },
    );
    try {
      await coordinator.start(fixture.parent, 20);
      final task = await started.future.timeout(const Duration(seconds: 2));
      coordinator.handleUpdate(TaskProgressUpdate(task, 0.999));
      coordinator.handleUpdate(TaskStatusUpdate(task, TaskStatus.running));
      coordinator.handleUpdate(TaskStatusUpdate(task, TaskStatus.canceled));
      await coordinator.handleNativeChunkUpdate(
        parentTaskId: fixture.parent.taskId,
        chunkTaskId: task.taskId,
        attemptGeneration:
            (jsonDecode(task.metaData) as Map)['attemptGeneration'] as int,
        writtenBytes: 10,
        expectedBytes: 10,
        completed: true,
      );
      expect(coordinator.activeConnectionCount, 0);
      expect(calls, 1);
      expect(starts, isEmpty);
      coordinator.handleUpdate(
        TaskStatusUpdate(task, TaskStatus.complete, null, null, {
          'content-range': 'bytes 0-9/20',
          'etag': '"same-resource"',
        }, 206),
      );
      await adopted.future.timeout(const Duration(seconds: 1));
      await cancelled.future.timeout(const Duration(seconds: 1));
      expect(await fixture.files.first.readAsBytes(), List.filled(10, 1));
      expect(await coordinator.pause(fixture.parent), isTrue);
      probe.complete((matches: false, validator: null));
      await probe.future;
      await coordinator.reconcile(() async => <String>{});
      final manifest = jsonDecode(
        await File('${await fixture.parent.filePath()}.parts/manifest.json')
            .readAsString(),
      ) as Map;
      expect((manifest['parts'] as List).first['complete'], isTrue);
      expect(starts, isEmpty);
    } finally {
      if (!probe.isCompleted) probe.complete((matches: false, validator: null));
      await coordinator.dispose();
      await fixture.dispose();
    }
  });

  for (final statThrows in [false, true]) {
    test(
      'canceled probe stat (throws=$statThrows) wakes another native parent',
      () async {
        final fixture = await SavedRangesFixture.create();
        final outside = Zone.current;
        final statEntered = Completer<void>();
        final releaseStat = Completer<void>();
        final nativeStarted = Completer<void>();
        var holdStat = false;
        var probes = 0;
        await IOOverrides.runZoned(
          () async {
            final coordinator = fixture.coordinator(
              maxActiveConnections: 1,
              startPart: (_, _, _) async {
                if (!nativeStarted.isCompleted) nativeStarted.complete();
                return true;
              },
              verifyPartSource: (_, _, _, _) async {
                probes++;
                return (matches: false, validator: null);
              },
            );
            try {
              await coordinator.start(fixture.parent, 20);
              holdStat = true;
              await statEntered.future.timeout(const Duration(seconds: 2));
              final other = fixture.parent.copyWith(
                taskId: 'aw_v2_stat_budget_g1',
                filename: 'other.mp4',
              );
              expect(await coordinator.start(other, 20), isTrue);
              expect(nativeStarted.isCompleted, isFalse);
              expect(await coordinator.pause(fixture.parent), isTrue);
              await coordinator.reconcile(() async => <String>{});
              expect(
                nativeStarted.isCompleted,
                isFalse,
                reason: 'the held stat still owns capacity',
              );
              releaseStat.complete();
              await nativeStarted.future.timeout(const Duration(seconds: 1));
              expect(probes, 0);
            } finally {
              if (!releaseStat.isCompleted) releaseStat.complete();
              await coordinator.dispose();
            }
          },
          stat: (path) async {
            if (holdStat &&
                !statEntered.isCompleted &&
                path == fixture.files.first.path) {
              statEntered.complete();
              await releaseStat.future;
              if (statThrows) {
                throw FileSystemException('controlled stat failure', path);
              }
            }
            return outside.run(() => FileStat.stat(path));
          },
        );
        await fixture.dispose();
      },
    );
  }

  test(
    'saved probes are bounded and count against the native connection budget',
    () async {
      final fixture = await SavedRangesFixture.create();
      final first = Completer<({bool matches, String? validator})>();
      final second = Completer<({bool matches, String? validator})>();
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final nativeStarted = Completer<void>();
      var probes = 0;
      var activeProbes = 0;
      var maxProbes = 0;
      final coordinator = fixture.coordinator(
        maxActiveConnections: 1,
        startPart: (task, _, _) async {
          expect(
            activeProbes,
            0,
            reason: 'a probe occupies the same one-connection budget',
          );
          if (!nativeStarted.isCompleted) nativeStarted.complete();
          return true;
        },
        verifyPartSource: (_, _, _, _) async {
          probes++;
          activeProbes++;
          if (activeProbes > maxProbes) maxProbes = activeProbes;
          final result = probes == 1 ? first : second;
          (probes == 1 ? firstStarted : secondStarted).complete();
          try {
            return await result.future;
          } finally {
            activeProbes--;
          }
        },
      );
      try {
        expect(await coordinator.start(fixture.parent, 20), isTrue);
        await firstStarted.future.timeout(const Duration(seconds: 2));
        final other = fixture.parent.copyWith(
          taskId: 'aw_v2_other_budget_g1',
          filename: 'other.mp4',
        );
        expect(await coordinator.start(other, 20), isTrue);
        expect(nativeStarted.isCompleted, isFalse);
        expect(probes, 1);
        first.complete((matches: true, validator: null));
        // Either next saved probe or the native parent may fairly win the slot.
        await Future.any([secondStarted.future, nativeStarted.future])
            .timeout(const Duration(seconds: 2));
        expect(maxProbes, 1);
        expect(
          activeProbes + coordinator.activeConnectionCount,
          lessThanOrEqualTo(1),
        );
      } finally {
        if (!first.isCompleted) {
          first.complete((matches: true, validator: null));
        }
        if (!second.isCompleted) {
          second.complete((matches: true, validator: null));
        }
        await coordinator.dispose();
        await fixture.dispose();
      }
    },
  );

  test('failed probe retries an uncertain pause inventory and preserves saved bytes', () async {
    final fixture = await SavedRangesFixture.create();
    final verification = Completer<({bool matches, String? validator})>();
    final started = Completer<void>();
    final paused = Completer<void>();
    var failNextInventory = false;
    var inventoryFailures = 0;
    final starts = <DownloadTask>[];
    final coordinator = fixture.coordinator(
      startPart: (task, _, _) async {
        starts.add(task);
        return true;
      },
      livePartIds: () async {
        if (failNextInventory) {
          failNextInventory = false;
          inventoryFailures++;
          throw StateError('one transient inventory failure');
        }
        return <String>{};
      },
      verifyPartSource: (_, _, _, _) {
        if (!started.isCompleted) started.complete();
        return verification.future;
      },
      onUpdate: (event) {
        if (event is TaskStatusUpdate &&
            event.status == TaskStatus.paused &&
            !paused.isCompleted) {
          paused.complete();
        }
      },
    );
    try {
      await coordinator.start(fixture.parent, 20);
      await started.future.timeout(const Duration(seconds: 2));
      failNextInventory = true;
      verification.complete((matches: false, validator: null));
      await paused.future.timeout(const Duration(seconds: 2));
      expect(inventoryFailures, 1);
      expect(coordinator.isActive(fixture.parent.taskId), isFalse);
      expect(starts, isEmpty);
      expect(await fixture.files.first.readAsBytes(), List.filled(10, 1));
      expect(await File(await fixture.parent.filePath()).exists(), isFalse);
    } finally {
      if (!verification.isCompleted) {
        verification.complete((matches: false, validator: null));
      }
      await coordinator.dispose();
      await fixture.dispose();
    }
  });

  test('rejected pause cannot remove the saved-range launch fence', () async {
    final fixture = await SavedRangesFixture.create();
    final first = Completer<({bool matches, String? validator})>();
    final second = Completer<({bool matches, String? validator})>();
    final started = Completer<void>();
    final restarted = Completer<void>();
    final starts = <DownloadTask>[];
    var probes = 0;
    final coordinator = fixture.coordinator(
      startPart: (task, _, _) async {
        starts.add(task);
        return true;
      },
      verifyPartSource: (_, _, _, _) {
        probes++;
        if (probes == 1) {
          started.complete();
          return first.future;
        }
        if (!restarted.isCompleted) restarted.complete();
        return second.future;
      },
      cancelPartSourceVerification: (_) {
        throw StateError('cancel hook failed');
      },
    );
    try {
      await coordinator.start(fixture.parent, 20);
      await started.future.timeout(const Duration(seconds: 2));
      await expectLater(
        coordinator.pause(
          fixture.parent,
          beforePause: () async {
            throw StateError('withdrawal rejected');
          },
        ),
        throwsStateError,
      );
      first.complete((matches: false, validator: null));
      await restarted.future.timeout(const Duration(seconds: 2));
      expect(
        starts,
        isEmpty,
        reason: 'rollback must re-verify, never overwrite exact bytes',
      );
      expect(coordinator.isActive(fixture.parent.taskId), isTrue);
      expect(await fixture.files.first.length(), 10);
      expect(await coordinator.pause(fixture.parent), isTrue);
    } finally {
      if (!first.isCompleted) first.complete((matches: true, validator: null));
      if (!second.isCompleted) {
        second.complete((matches: true, validator: null));
      }
      await coordinator.dispose();
      await fixture.dispose();
    }
  });

  for (final mutationPoint in ['inventory', 'native settlement']) {
    test(
      'verified bytes changed during $mutationPoint are not adopted',
      () async {
        final fixture = await SavedRangesFixture.create();
        final started = Completer<void>();
        final verification = Completer<({bool matches, String? validator})>();
        final inventoryEntered = Completer<void>();
        final releaseInventory = Completer<void>();
        final paused = Completer<void>();
        var holdInventory = false;
        var nativeOwner = false;
        var completedParts = 0;
        Future<void> changeFile() async {
          await fixture.files.first.writeAsBytes(List.filled(10, 9));
          await fixture.files.first.setLastModified(DateTime.utc(2000));
        }

        final coordinator = fixture.coordinator(
          livePartIds: () async {
            if (holdInventory) {
              holdInventory = false;
              inventoryEntered.complete();
              await releaseInventory.future;
              if (mutationPoint == 'inventory') await changeFile();
              if (mutationPoint == 'native settlement') nativeOwner = true;
            }
            return nativeOwner ? {fixture.parts.first.taskId} : <String>{};
          },
          pausePart: (_) async {
            await changeFile();
            nativeOwner = false;
          },
          verifyPartSource: (_, _, _, _) {
            if (!started.isCompleted) started.complete();
            return verification.future;
          },
          saveRecord: (record) async {
            if (record.taskId.contains('.part.') &&
                record.status == TaskStatus.complete) {
              completedParts++;
            }
          },
          onUpdate: (event) {
            if (event is TaskStatusUpdate &&
                event.status == TaskStatus.paused &&
                !paused.isCompleted) {
              paused.complete();
            }
          },
        );
        try {
          await coordinator.start(fixture.parent, 20);
          await started.future.timeout(const Duration(seconds: 2));
          holdInventory = true;
          verification.complete((matches: true, validator: null));
          await inventoryEntered.future.timeout(const Duration(seconds: 2));
          releaseInventory.complete();
          await paused.future.timeout(const Duration(seconds: 2));
          expect(completedParts, 0);
          expect(await fixture.files.first.readAsBytes(), List.filled(10, 9));
          expect(await File(await fixture.parent.filePath()).exists(), isFalse);
        } finally {
          if (!verification.isCompleted) {
            verification.complete((matches: false, validator: null));
          }
          if (!releaseInventory.isCompleted) releaseInventory.complete();
          await coordinator.dispose();
          await fixture.dispose();
        }
      },
    );
  }
}

class SavedRangesFixture {
  SavedRangesFixture(this.root, this.parent, this.parts, this.files);
  final Directory root;
  final ParallelDownloadTask parent;
  final List<DownloadTask> parts;
  final List<File> files;

  static Future<SavedRangesFixture> create() async {
    final root = await Directory.systemTemp.createTemp('saved-range-probes-');
    final parent = ParallelDownloadTask(
      taskId: 'aw_v2_saved_probes_g1',
      url: 'https://example.invalid/video',
      filename: 'video.mp4',
      directory: root.path,
      baseDirectory: BaseDirectory.root,
      chunks: 2,
      allowPause: true,
    );
    final seed = PersistentParallelDownload(
      startPart: (_, _, _) async => true,
      pausePart: (_) async {},
      cancelParts: (_) async {},
      saveRecord: (_) async {},
      recordForId: (_) async => null,
      onUpdate: (_) {},
      onPartProgress: (_, _, _) {},
      diskProgressPollInterval: const Duration(hours: 1),
    );
    await seed.start(parent, 20);
    await seed.dispose();
    final manifest = jsonDecode(
      await File('${await parent.filePath()}.parts/manifest.json')
          .readAsString(),
    ) as Map;
    final parts = <DownloadTask>[];
    final files = <File>[];
    for (final raw in manifest['parts'] as List) {
      final task = Task.createFromJson(
        Map<String, dynamic>.from(raw['task'] as Map),
      ) as DownloadTask;
      parts.add(task);
      files.add(
        await File(await task.filePath()).writeAsBytes(List.filled(10, 1)),
      );
    }
    return SavedRangesFixture(root, parent, parts, files);
  }

  PersistentParallelDownload coordinator({
    Future<bool> Function(DownloadTask, double, int)? startPart,
    Future<void> Function(DownloadTask)? pausePart,
    Future<Set<String>> Function()? livePartIds,
    Future<void> Function(TaskRecord)? saveRecord,
    void Function(TaskUpdate)? onUpdate,
    required Future<({bool matches, String? validator})> Function(
      DownloadTask,
      File,
      int,
      int,
    )
    verifyPartSource,
    void Function(String)? cancelPartSourceVerification,
    int maxActiveConnections = 16,
  }) => PersistentParallelDownload(
    startPart: startPart ?? (_, _, _) async => true,
    pausePart: pausePart ?? (_) async {},
    cancelParts: (_) async {},
    saveRecord: saveRecord ?? (_) async {},
    recordForId: (_) async => null,
    onUpdate: onUpdate ?? (_) {},
    onPartProgress: (_, _, _) {},
    livePartIds: livePartIds ?? () async => <String>{},
    verifyPartSource: verifyPartSource,
    cancelPartSourceVerification: cancelPartSourceVerification,
    maxActiveConnections: maxActiveConnections,
    recoveryDelay: Duration.zero,
    promoteFile: publishCompletedTestFile,
    diskProgressPollInterval: const Duration(hours: 1),
  );

  Future<void> dispose() => root.delete(recursive: true);
}
