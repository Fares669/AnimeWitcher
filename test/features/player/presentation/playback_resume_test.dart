import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/features/player/presentation/playback_resume.dart';

void main() {
  group('PlaybackResume.shouldHoldUntilSeeked', () {
    test('holds for a mid-episode bookmark', () {
      expect(PlaybackResume.shouldHoldUntilSeeked(15 * 60 * 1000), isTrue);
    });

    test('does not hold a fresh start', () {
      expect(PlaybackResume.shouldHoldUntilSeeked(0), isFalse);
      expect(PlaybackResume.shouldHoldUntilSeeked(500), isFalse);
      expect(
        PlaybackResume.shouldHoldUntilSeeked(PlaybackResume.minPositionMs - 1),
        isFalse,
      );
      expect(
        PlaybackResume.shouldHoldUntilSeeked(PlaybackResume.minPositionMs),
        isTrue,
      );
    });
  });

  group('PlaybackResume.isNear', () {
    test('accepts HLS keyframe landings within the settle window', () {
      expect(
        PlaybackResume.isNear(currentMs: 180_000, targetMs: 184_000),
        isTrue,
      );
      expect(PlaybackResume.isNear(currentMs: 0, targetMs: 180_000), isFalse);
    });
  });

  group('PlaybackResume.canRevealVideo', () {
    test('hides the first frames until the playhead reaches the bookmark', () {
      expect(
        PlaybackResume.canRevealVideo(
          pendingResumeMs: 180000,
          applyingResume: false,
          currentMs: 400,
        ),
        isFalse,
      );
      expect(
        PlaybackResume.canRevealVideo(
          pendingResumeMs: 180000,
          applyingResume: true,
          currentMs: 180000,
        ),
        isFalse,
      );
      expect(
        PlaybackResume.canRevealVideo(
          pendingResumeMs: 180000,
          applyingResume: false,
          currentMs: 180200,
        ),
        isTrue,
      );
    });

    test('reveals a fresh start as soon as playback advances', () {
      expect(
        PlaybackResume.canRevealVideo(
          pendingResumeMs: null,
          applyingResume: false,
          currentMs: 80,
        ),
        isTrue,
      );
    });
  });

  group('PlaybackResume.shouldAwaitCloudResume', () {
    test('never waits on the network for a downloaded file', () {
      expect(
        PlaybackResume.shouldAwaitCloudResume(
          isLocalPlayback: true,
          localPositionMs: 0,
        ),
        isFalse,
      );
      expect(
        PlaybackResume.shouldAwaitCloudResume(
          isLocalPlayback: true,
          localPositionMs: 180000,
        ),
        isFalse,
      );
    });

    test('skips the cloud when streaming already has a local bookmark', () {
      expect(
        PlaybackResume.shouldAwaitCloudResume(
          isLocalPlayback: false,
          localPositionMs: 15000,
        ),
        isFalse,
      );
    });

    test('asks the cloud only when streaming has no usable bookmark', () {
      expect(
        PlaybackResume.shouldAwaitCloudResume(
          isLocalPlayback: false,
          localPositionMs: 0,
        ),
        isTrue,
      );
    });
  });

  group('PlaybackResume.resolveStartupPosition', () {
    test('opens a downloaded file immediately even if cloud resume hangs',
        () async {
      final never = Completer<int>();
      var cloudCalled = false;
      final stopwatch = Stopwatch()..start();
      final position = await PlaybackResume.resolveStartupPosition(
        localPositionMs: 0,
        isLocalPlayback: true,
        cloudPositionMs: () {
          cloudCalled = true;
          return never.future;
        },
      );
      stopwatch.stop();

      expect(position, 0);
      expect(cloudCalled, isFalse);
      expect(stopwatch.elapsedMilliseconds, lessThan(200));
    });

    test('keeps a downloaded bookmark without consulting the cloud', () async {
      final never = Completer<int>();
      final position = await PlaybackResume.resolveStartupPosition(
        localPositionMs: 12000,
        isLocalPlayback: true,
        cloudPositionMs: () => never.future,
      );
      expect(position, 12000);
    });

    test('uses a cloud bookmark when streaming has no local progress', () async {
      final position = await PlaybackResume.resolveStartupPosition(
        localPositionMs: 0,
        isLocalPlayback: false,
        cloudPositionMs: () async => 90000,
      );
      expect(position, 90000);
    });
  });
}
