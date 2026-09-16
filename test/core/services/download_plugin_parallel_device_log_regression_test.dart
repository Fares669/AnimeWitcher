import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'zero-byte plugin parallel source refresh discards stale opaque resume state',
    () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();

      expect(
        source,
        contains('_resetZeroBytePluginParallelResumeState('),
        reason:
            'device logs show a refreshed parent can otherwise resume stale child URLs and loop on HTTP 403',
      );
      expect(
        source,
        contains('partialBytes <= 0'),
        reason: 'resume state may only be discarded when no durable bytes exist',
      );
      expect(
        source,
        contains('BackgroundDownloaderCompat.clearResumeStateForTaskIds('),
        reason:
            'the stale background_downloader ResumeData/pausedTask must be removed before rebuilding chunks',
      );
      expect(
        source,
        contains('source.refreshPluginParallelZeroByteReset'),
        reason: 'the recovery path must be explicit in diagnostic logs',
      );
    },
  );

  test('plugin parallel parent pause is ignored while a chunk writer is live', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();

    expect(source, contains('Future<bool> _hasLivePluginParallelChunks('));
    expect(source, contains('FileDownloader().allTasks(allGroups: true)'));
    expect(
      source,
      contains('downloadInternalParentTaskId(candidate) == parentTaskId'),
    );
    expect(
      source,
      contains('paused.pluginParallelLiveChildIgnored'),
      reason:
          'device logs showed parent paused callbacks while child byte progress was still increasing',
    );
  });
}
