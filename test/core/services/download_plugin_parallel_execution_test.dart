import 'dart:io';

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/download_transport_policy.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'accepted 8-connection download builds one plugin ParallelDownloadTask',
    () {
      final template = DownloadTask(
        taskId: 'episode-plugin-parallel',
        url: 'https://cdn.example.test/episode.mp4',
        filename: 'episode.mp4',
        group: kLogicalDownloadGroup,
        updates: Updates.statusAndProgress,
        allowPause: true,
      );

      final task = buildPluginTransportTask(template: template, connections: 8);

      expect(task, isA<ParallelDownloadTask>());
      final parallel = task as ParallelDownloadTask;
      expect(parallel.chunks, 8);
      expect(parallel.taskId, template.taskId);
      expect(parallel.group, kLogicalDownloadGroup);
      expect(parallel.taskId, isNot(contains('.part.')));
      expect(parallel.group, isNot(kPersistentDownloadChunkGroup));
    },
  );

  test('production provider wires the platform acceptance gate', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final providerStart = source.indexOf(
      '@Riverpod(keepAlive: true)\nDownloadService downloadService(Ref ref)',
    );
    final providerEnd = source.indexOf('enum DownloadCommandOutcome', providerStart);
    expect(providerStart, greaterThanOrEqualTo(0));
    expect(providerEnd, greaterThan(providerStart));
    final provider = source.substring(providerStart, providerEnd);

    expect(
      provider,
      contains('pluginParallelAcceptedForPlatform(defaultTargetPlatform)'),
      reason:
          'production must not leave the constructor default false and silently disable accepted plugin-parallel platforms',
    );
  });

  test(
    'fresh parallel start is selected by policy before legacy multipart',
    () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();

      expect(source, contains("import 'download_transport_policy.dart';"));
      expect(source, contains('bool pluginParallelAccepted = false'));
      expect(
        source,
        contains('_pluginParallelAccepted = pluginParallelAccepted'),
      );

      final start = source.indexOf('Future<bool> _enqueueTransfer(');
      final end = source.indexOf(
        'Future<DownloadResourceFingerprint?> _probeResourceFingerprint(',
        start,
      );
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(
        body,
        contains('final legacySessionExists = await _parallel.restore(task);'),
      );
      expect(body, contains('selectDownloadExecutionBackend('));
      expect(body, contains('pluginParallelAccepted: _pluginParallelAccepted'));
      expect(body, contains('legacySessionExists: legacySessionExists'));
      expect(body, contains('DownloadExecutionBackend.pluginParallel'));
      expect(body, contains('_nativeTransport.start(task)'));
      expect(body, contains('_parallel.start(task, totalBytes)'));
    },
  );

  test('paused plugin parallel resumes parent before any fresh chunk enqueue', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final methodStart = source.indexOf('Future<bool> _resumeDownloadTask(');
    final methodEnd = source.indexOf(
      'Future<bool> _resumeUsingPartialFile(',
      methodStart,
    );
    expect(methodStart, greaterThanOrEqualTo(0));
    expect(methodEnd, greaterThan(methodStart));
    final body = source.substring(methodStart, methodEnd);

    final parallelStart = body.indexOf('if (task is ParallelDownloadTask) {');
    final parallelEnd = body.indexOf(
      '// Only a validated source replacement may cross the custom Range seam.',
      parallelStart,
    );
    expect(parallelStart, greaterThanOrEqualTo(0));
    expect(parallelEnd, greaterThan(parallelStart));
    final parallel = body.substring(parallelStart, parallelEnd);

    final legacyRestore = parallel.indexOf('await _parallel.restore(task)');
    final pluginResume = parallel.indexOf(
      'await _nativeTransport.resume(task)',
    );
    final legacyImport = parallel.indexOf(
      'BackgroundDownloaderCompat.resumeDataForTaskId',
    );
    final freshEnqueue = parallel.indexOf(
      '_enqueueTransfer(task, saved.totalSize)',
    );

    expect(legacyRestore, greaterThanOrEqualTo(0));
    expect(
      pluginResume,
      greaterThan(legacyRestore),
      reason:
          'without a legacy manifest, a paused ParallelDownloadTask must resume through background_downloader',
    );
    if (legacyImport >= 0) {
      expect(
        pluginResume,
        lessThan(legacyImport),
        reason: 'plugin parent resume must be attempted before legacy adoption',
      );
    }
    expect(freshEnqueue, greaterThan(pluginResume));
  });
}
