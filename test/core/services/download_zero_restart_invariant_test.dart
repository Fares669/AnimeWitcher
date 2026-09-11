import 'package:animewitcher/core/utils/download_resume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('zero restart invariant', () {
    test('visible partial bytes always block restart from zero', () {
      expect(
        shouldRestartDownloadFromZero(
          existingPartialBytes: 1,
          expectedBytes: 1000,
        ),
        isFalse,
      );
      expect(
        chooseDownloadResumeStrategy(
          canNativeResume: false,
          existingPartialBytes: 1,
          expectedBytes: 1000,
        ),
        DownloadResumeStrategy.partialFile,
      );
    });

    test('exact-size local bytes stay on the local completion path', () {
      expect(
        shouldRestartDownloadFromZero(
          existingPartialBytes: 1000,
          expectedBytes: 1000,
          savedProgress: 0,
        ),
        isFalse,
      );
      expect(
        chooseDownloadResumeStrategy(
          canNativeResume: false,
          existingPartialBytes: 1000,
          expectedBytes: 1000,
          savedProgress: 0,
        ),
        DownloadResumeStrategy.partialFile,
        reason:
            'an exact-size durable file must be adopted/completed, never stranded or restarted',
      );
    });

    test('saved progress blocks restart even when native temp is hidden', () {
      expect(
        shouldRestartDownloadFromZero(
          existingPartialBytes: 0,
          expectedBytes: 1000,
          savedProgress: 0.42,
        ),
        isFalse,
      );
      expect(
        chooseDownloadResumeStrategy(
          canNativeResume: false,
          existingPartialBytes: 0,
          expectedBytes: 1000,
          savedProgress: 0.42,
        ),
        DownloadResumeStrategy.partialFile,
      );
    });

    test('native resume wins without discarding disk prefix', () {
      expect(
        chooseDownloadResumeStrategy(
          canNativeResume: true,
          existingPartialBytes: 650,
          expectedBytes: 1000,
          savedProgress: 0.65,
        ),
        DownloadResumeStrategy.nativeResume,
      );
      expect(
        shouldRestartDownloadFromZero(
          existingPartialBytes: 650,
          expectedBytes: 1000,
          savedProgress: 0.65,
        ),
        isFalse,
      );
    });

    test('fresh zero start is allowed only with no durable evidence', () {
      expect(
        shouldRestartDownloadFromZero(
          existingPartialBytes: 0,
          expectedBytes: 1000,
          savedProgress: 0,
        ),
        isTrue,
      );
      expect(
        chooseDownloadResumeStrategy(
          canNativeResume: false,
          existingPartialBytes: 0,
          expectedBytes: 1000,
          savedProgress: 0,
        ),
        DownloadResumeStrategy.restartFromZero,
      );
    });
  });
}
