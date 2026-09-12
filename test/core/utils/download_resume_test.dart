import 'dart:io';

import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/utils/download_resume.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('unknown native size cannot hide a durable expected length', () {
    expect(knownDownloadSize([-1, 0, 1024]), 1024);
    expect(knownDownloadSize([null, 2048, 1024]), 2048);
    expect(knownDownloadSize([4096, -1, 1024]), 4096);
    expect(knownDownloadSize([null, -1, 0]), -1);
  });
  test('complete or oversized saved files never restart from zero', () async {
    for (final bytes in [10, 11]) {
      var restarts = 0;
      expect(
        await resumeOrRestartDownload(
          canResume: () async => false,
          resume: () async => false,
          resumeFromPartial: () async => false,
          restart: () async {
            restarts++;
            return true;
          },
          existingPartialBytes: bytes,
          expectedBytes: 10,
        ),
        isFalse,
      );
      expect(restarts, 0);
    }
  });

  test(
    'relaunch recovers system pauses but respects user pause and delete',
    () {
      for (final status in [
        TaskStatus.paused,
        TaskStatus.failed,
        TaskStatus.notFound,
        TaskStatus.canceled,
      ]) {
        expect(
          shouldRequeueInterruptedDownloadAfterRelaunch(
            persisted: status,
            queueWaiting: false,
            userPaused: false,
            stillInNativeQueue: false,
            hasMetadata: true,
          ),
          isTrue,
        );
        expect(
          shouldRequeueInterruptedDownloadAfterRelaunch(
            persisted: status,
            queueWaiting: false,
            userPaused: true,
            stillInNativeQueue: false,
            hasMetadata: true,
          ),
          isFalse,
        );
        expect(
          shouldRequeueInterruptedDownloadAfterRelaunch(
            persisted: status,
            queueWaiting: false,
            userPaused: false,
            stillInNativeQueue: false,
            hasMetadata: false,
          ),
          isFalse,
        );
      }
    },
  );
  test(
    'uses a successful native resume when resume data is available',
    () async {
      var resumeCalls = 0;
      var restartCalls = 0;

      final result = await resumeOrRestartDownload(
        canResume: () async => true,
        resume: () async {
          resumeCalls++;
          return true;
        },
        restart: () async {
          restartCalls++;
          return true;
        },
      );

      expect(result, isTrue);
      expect(resumeCalls, 1);
      expect(restartCalls, 0);
    },
  );

  test('restarts when native resume data is unavailable', () async {
    var resumeCalls = 0;
    var restartCalls = 0;

    final result = await resumeOrRestartDownload(
      canResume: () async => false,
      resume: () async {
        resumeCalls++;
        return true;
      },
      restart: () async {
        restartCalls++;
        return true;
      },
    );

    expect(result, isTrue);
    expect(resumeCalls, 0);
    expect(restartCalls, 1);
  });

  test('keeps leftover bytes before restarting from zero', () async {
    var partialCalls = 0;
    var restartCalls = 0;

    final result = await resumeOrRestartDownload(
      canResume: () async => false,
      resume: () async => false,
      resumeFromPartial: () async {
        partialCalls++;
        return true;
      },
      restart: () async {
        restartCalls++;
        return true;
      },
    );

    expect(result, isTrue);
    expect(partialCalls, 1);
    expect(restartCalls, 0);
  });

  test('restarts when a native resume attempt is rejected', () async {
    var restartCalls = 0;

    final result = await resumeOrRestartDownload(
      canResume: () async => true,
      resume: () async => false,
      restart: () async {
        restartCalls++;
        return false;
      },
    );

    expect(result, isFalse);
    expect(restartCalls, 1);
  });

  test('restarts when a native resume attempt throws', () async {
    var restartCalls = 0;

    final result = await resumeOrRestartDownload(
      canResume: () async => true,
      resume: () async => throw StateError('stale resume data'),
      restart: () async {
        restartCalls++;
        return true;
      },
    );

    expect(result, isTrue);
    expect(restartCalls, 1);
  });

  test('historical saved progress alone does not block zero restart', () async {
    var restartCalls = 0;

    final result = await resumeOrRestartDownload(
      canResume: () async => false,
      resume: () async => false,
      restart: () async {
        restartCalls++;
        return true;
      },
      savedProgress: 0.42,
    );

    expect(result, isTrue);
    expect(restartCalls, 1);
  });

  test(
    'does not restart from zero after a failed native resume if bytes remain',
    () async {
      var restartCalls = 0;

      final result = await resumeOrRestartDownload(
        canResume: () async => true,
        resume: () async => false,
        restart: () async {
          restartCalls++;
          return true;
        },
        existingPartialBytes: 2048,
        expectedBytes: 10000,
      );

      expect(result, isFalse);
      expect(restartCalls, 0);
    },
  );

  test('keeps progress monotonic across stale callbacks', () {
    expect(keepLastKnownDownloadProgress(incoming: 0, lastKnown: 0.37), 0.37);
    expect(keepLastKnownDownloadProgress(incoming: 0.2, lastKnown: 0.37), 0.37);
    expect(keepLastKnownDownloadProgress(incoming: 0.5, lastKnown: 0.37), 0.5);
    expect(keepLastKnownDownloadProgress(incoming: -1, lastKnown: 0.37), 0.37);
    expect(keepLastKnownDownloadProgress(incoming: 0, lastKnown: 0), 0);
  });

  test('restarts when checking resumability throws for a stale task', () async {
    var restartCalls = 0;

    final result = await resumeOrRestartDownload(
      canResume: () async => throw StateError('missing resume metadata'),
      resume: () async => true,
      restart: () async {
        restartCalls++;
        return true;
      },
    );

    expect(result, isTrue);
    expect(restartCalls, 1);
  });

  test('prefers native resume, then leftover bytes, then a full restart', () {
    expect(
      chooseDownloadResumeStrategy(
        canNativeResume: true,
        existingPartialBytes: 40,
        expectedBytes: 100,
      ),
      DownloadResumeStrategy.nativeResume,
    );
    expect(
      chooseDownloadResumeStrategy(
        canNativeResume: false,
        existingPartialBytes: 40,
        expectedBytes: 100,
      ),
      DownloadResumeStrategy.partialFile,
    );
    expect(
      chooseDownloadResumeStrategy(
        canNativeResume: false,
        existingPartialBytes: 0,
        expectedBytes: 100,
        savedProgress: 0.4,
      ),
      DownloadResumeStrategy.restartFromZero,
    );
    expect(
      shouldRestartDownloadFromZero(
        existingPartialBytes: 40,
        expectedBytes: 100,
      ),
      isFalse,
    );
    expect(
      shouldRestartDownloadFromZero(
        existingPartialBytes: 0,
        expectedBytes: 100,
        savedProgress: 0.25,
      ),
      isTrue,
    );
    expect(
      shouldRestartDownloadFromZero(
        existingPartialBytes: 0,
        expectedBytes: 100,
      ),
      isTrue,
    );
    expect(
      shouldResumeFromPartialBytes(
        existingPartialBytes: 40,
        expectedBytes: 100,
      ),
      isTrue,
    );
    expect(
      shouldResumeFromPartialBytes(
        existingPartialBytes: 100,
        expectedBytes: 100,
      ),
      isFalse,
    );
  });

  test('auto-resumes killed running downloads but not user-paused ones', () {
    expect(
      shouldAutoResumeInterruptedDownload(
        wasRunningOrFailed: true,
        userPaused: false,
        stillInNativeQueue: false,
      ),
      isTrue,
    );
    expect(
      shouldAutoResumeInterruptedDownload(
        wasRunningOrFailed: true,
        userPaused: false,
        stillInNativeQueue: true,
      ),
      isFalse,
    );
    expect(
      shouldAutoResumeInterruptedDownload(
        wasRunningOrFailed: true,
        userPaused: false,
        stillInNativeQueue: false,
        queueWaiting: true,
      ),
      isFalse,
    );
    expect(
      shouldAutoResumeInterruptedDownload(
        wasRunningOrFailed: false,
        userPaused: true,
        stillInNativeQueue: false,
      ),
      isFalse,
    );
  });

  test('relaunch restores failures and system pauses but not user pauses', () {
    for (final status in <TaskStatus>[
      TaskStatus.failed,
      TaskStatus.notFound,
      TaskStatus.canceled,
      TaskStatus.paused,
    ]) {
      expect(
        shouldRequeueInterruptedDownloadAfterRelaunch(
          persisted: status,
          queueWaiting: false,
          userPaused: false,
          stillInNativeQueue: false,
          hasMetadata: true,
        ),
        isTrue,
        reason: '$status should be recoverable with metadata',
      );
    }
    expect(
      shouldRequeueInterruptedDownloadAfterRelaunch(
        persisted: TaskStatus.paused,
        queueWaiting: false,
        userPaused: true,
        stillInNativeQueue: false,
        hasMetadata: true,
      ),
      isFalse,
    );
    expect(
      shouldRequeueInterruptedDownloadAfterRelaunch(
        persisted: TaskStatus.canceled,
        queueWaiting: false,
        userPaused: false,
        stillInNativeQueue: false,
        hasMetadata: false,
      ),
      isFalse,
    );
    expect(
      shouldRequeueInterruptedDownloadAfterRelaunch(
        persisted: TaskStatus.failed,
        queueWaiting: false,
        userPaused: false,
        stillInNativeQueue: true,
        hasMetadata: true,
      ),
      isFalse,
    );
  });

  test(
    'kill recovery re-enqueues native holding-queue waiters, not user-paused',
    () {
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
          queueWaiting: false,
          userPaused: true,
          stillInNativeQueue: false,
        ),
        isFalse,
      );
    },
  );

  test('range headers continue from the existing byte offset', () {
    expect(
      rangeResumeHeaders(
        existing: const {'Authorization': 'Bearer x', 'Range': 'bytes=0-0'},
        existingBytes: 2048,
      ),
      {'Authorization': 'Bearer x', 'Range': 'bytes=2048-'},
    );
  });

  test('finds the largest leftover dest or sibling temp file', () async {
    final root = await Directory.systemTemp.createTemp('aw-resume-');
    addTearDown(() => root.delete(recursive: true));
    final dest = File(p.join(root.path, 'ep.mp4'));
    await dest.writeAsBytes(List<int>.filled(10, 1));
    await File(p.join(root.path, 'ep.mp4.download'))
        .writeAsBytes(List<int>.filled(40, 2));

    final found = await findPartialDownloadFile(destinationPath: dest.path);
    expect(found, isNotNull);
    expect(p.basename(found!.path), 'ep.mp4.download');
    expect(await found.length(), 40);
  });

  test(
    'canonicalizes the largest temp prefix without keeping a duplicate',
    () async {
      final root = await Directory.systemTemp.createTemp('aw-canonical-');
      addTearDown(() => root.delete(recursive: true));
      final dest = File(p.join(root.path, '0.part'));
      await dest.writeAsBytes(List<int>.filled(10, 1));
      final temp = File('${dest.path}.download');
      await temp.writeAsBytes(List<int>.filled(40, 2));

      final result = await canonicalizePartialDownloadFile(
        destinationPath: dest.path,
      );
      expect(result, isNotNull);
      expect(result!.file.path, dest.path);
      expect(result.bytes, 40);
      expect(await dest.length(), 40);
      expect(await dest.readAsBytes(), List<int>.filled(40, 2));
      expect(await temp.exists(), isFalse);
    },
  );

  test('moves a suffix prefix into an absent canonical destination', () async {
    final root = await Directory.systemTemp.createTemp('aw-canonical-empty-');
    addTearDown(() => root.delete(recursive: true));
    final dest = File(p.join(root.path, 'episode.mp4'));
    final temp = File('${dest.path}.tmp');
    await temp.writeAsBytes(List<int>.filled(64, 7));

    final result = await canonicalizePartialDownloadFile(
      destinationPath: dest.path,
    );

    expect(result, isNotNull);
    expect(result!.bytes, 64);
    expect(await dest.exists(), isTrue);
    expect(await dest.length(), 64);
    expect(await temp.exists(), isFalse);
  });

  test(
    'keeps canonical destination when it already has the most bytes',
    () async {
      final root = await Directory.systemTemp.createTemp('aw-canonical-best-');
      addTearDown(() => root.delete(recursive: true));
      final dest = File(p.join(root.path, 'episode.mp4'));
      final temp = File('${dest.path}.download');
      await dest.writeAsBytes(List<int>.filled(80, 3));
      await temp.writeAsBytes(List<int>.filled(40, 4));

      final result = await canonicalizePartialDownloadFile(
        destinationPath: dest.path,
      );

      expect(result, isNotNull);
      expect(result!.bytes, 80);
      expect(await dest.length(), 80);
      // Do not delete a sibling merely because it is smaller. A native worker
      // may still own it; cleanup remains the explicit cancel/delete path.
      expect(await temp.exists(), isTrue);
    },
  );

  test('append keeps the existing prefix and adds the rest', () async {
    final root = await Directory.systemTemp.createTemp('aw-append-');
    addTearDown(() => root.delete(recursive: true));
    final dest = File(p.join(root.path, 'ep.mp4'));
    await dest.writeAsBytes(const [1, 2, 3, 4]);

    final written = await appendDownloadChunks(
      dest: dest,
      chunks: Stream<List<int>>.fromIterable(const [
        [5, 6],
        [7],
      ]),
      existingBytes: 4,
    );

    expect(written, 7);
    expect(await dest.readAsBytes(), [1, 2, 3, 4, 5, 6, 7]);
  });
}
