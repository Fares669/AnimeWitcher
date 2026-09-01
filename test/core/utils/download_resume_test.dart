import 'dart:io';

import 'package:animewitcher/core/services/download_concurrency.dart';
import 'package:animewitcher/core/utils/download_resume.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
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

  test('does not restart from zero when saved progress exists', () async {
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

    expect(result, isFalse);
    expect(restartCalls, 0);
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

  test('keeps last known percent instead of flashing zero', () {
    expect(keepLastKnownDownloadProgress(incoming: 0, lastKnown: 0.37), 0.37);
    expect(keepLastKnownDownloadProgress(incoming: 0.5, lastKnown: 0.37), 0.5);
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
      DownloadResumeStrategy.partialFile,
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
      isFalse,
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
    await File(
      p.join(root.path, 'ep.mp4.download'),
    ).writeAsBytes(List<int>.filled(40, 2));

    final found = await findPartialDownloadFile(destinationPath: dest.path);
    expect(found, isNotNull);
    expect(p.basename(found!.path), 'ep.mp4.download');
    expect(await found.length(), 40);
  });

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
