import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DM-08 wires opaque native resume to explicit restartRequired outcome', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();

    expect(
      source,
      contains('on _DownloadRestartRequiredException'),
      reason:
          'resumeDownloadOutcome must surface the typed restart-required result',
    );
    expect(
      source,
      contains(
        'hasOpaqueNativeResume: canNativeResume && saved.partialBytes <= 0',
      ),
      reason:
          'source refresh must know when native resume data is the only byte owner',
    );
    expect(
      source,
      contains('restartRequired: true'),
      reason:
          'a validated replacement source must not silently discard opaque bytes',
    );
    expect(
      source,
      contains('throw _DownloadRestartRequiredException(task.taskId);'),
      reason:
          'opaque bytes that cannot migrate must stop before zero-byte restart',
    );

    final nativeProbe = source.indexOf('await _canNativeResume(task)');
    expect(nativeProbe, greaterThanOrEqualTo(0));
    final refresh = source.indexOf(
      'final refreshResult = await _refreshTaskBeforeResume(',
      nativeProbe,
    );
    expect(
      refresh,
      greaterThan(nativeProbe),
      reason: 'native ownership must be identified before source replacement',
    );
  });

  test('Task 8 isolates custom Range to validated refreshed-source recovery', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final resumeStart = source.indexOf(
      'Future<bool> _resumeDownloadTask(DownloadTask task) async {',
    );
    final rangeHelper = source.indexOf(
      'Future<bool> _resumeUsingPartialFile(',
      resumeStart,
    );
    expect(resumeStart, greaterThanOrEqualTo(0));
    expect(rangeHelper, greaterThan(resumeStart));

    final resumeBody = source.substring(resumeStart, rangeHelper);
    expect(
      resumeBody,
      contains('planRefreshedTransferResume('),
      reason:
          'a changed signed URL must go through the explicit refresh-resume planner',
    );
    expect(
      resumeBody,
      contains('RefreshedTransferResumeMode.verifiedRangeFallback'),
      reason:
          'custom Range is allowed only as the planner-selected exceptional seam',
    );

    final ordinaryFallback = resumeBody.indexOf('return resumeOrRestartDownload(');
    expect(ordinaryFallback, greaterThanOrEqualTo(0));
    final ordinaryBody = resumeBody.substring(ordinaryFallback);
    expect(
      ordinaryBody,
      isNot(contains('resumeFromPartial: () => _resumeUsingPartialFile(task)')),
      reason:
          'ordinary resume/retry must stay plugin-owned instead of using custom Range',
    );
  });
}
