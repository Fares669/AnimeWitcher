import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/features/player/presentation/playback_resume.dart';

void main() {
  group('PlaybackResume.openWhenReady', () {
    test('exiting during startup position lookup prevents autoplay', () async {
      final cloud = Completer<int>();
      var active = true;
      var opens = 0;
      final startup = PlaybackResume.openWhenReady(
        isActive: () => active,
        resolvePosition: () => cloud.future,
        open: (_) async {
          opens++;
        },
      );

      // Back stops the engine while the no-bookmark path is still waiting.
      active = false;
      cloud.complete(0);
      expect(await startup, isFalse);
      expect(opens, 0);
    });

    test('a late bookmark cannot open over a replacement episode', () async {
      final cloud = Completer<int>();
      var currentSession = 1;
      final requestedSession = currentSession;
      var opens = 0;
      final startup = PlaybackResume.openWhenReady(
        isActive: () => currentSession == requestedSession,
        resolvePosition: () => cloud.future,
        open: (_) async {
          opens++;
        },
      );
      currentSession = 2;
      cloud.complete(90000);
      expect(await startup, isFalse);
      expect(opens, 0);
    });

    test('position lookup fallback cannot autoplay after leaving', () async {
      final cloud = Completer<int>();
      var active = true;
      var opens = 0;
      final startup = PlaybackResume.openWhenReady(
        isActive: () => active,
        resolvePosition: () => cloud.future.catchError((_) => 0),
        open: (_) async {
          opens++;
        },
      );
      active = false;
      cloud.completeError(StateError('offline'));
      expect(await startup, isFalse);
      expect(opens, 0);
    });

    test('active playback keeps the existing resume position', () async {
      int? openedAt;
      final opened = await PlaybackResume.openWhenReady(
        isActive: () => true,
        resolvePosition: () async => 120000,
        open: (position) async {
          openedAt = position;
        },
      );
      expect(opened, isTrue);
      expect(openedAt, 120000);
    });

    test('exit during engine open skips subsequent resume work', () async {
      final opening = Completer<void>();
      final started = Completer<void>();
      var active = true;
      final startup = PlaybackResume.openWhenReady(
        isActive: () => active,
        resolvePosition: () async => 90000,
        open: (_) {
          started.complete();
          return opening.future;
        },
      );
      await started.future;
      active = false;
      opening.complete();
      expect(await startup, isFalse);
    });
  });

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
}
