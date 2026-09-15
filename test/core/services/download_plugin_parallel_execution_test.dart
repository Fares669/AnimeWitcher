import 'dart:io';

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/download_transport_policy.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepted 8-connection download builds one plugin ParallelDownloadTask', () {
    final template = DownloadTask(
      taskId: 'episode-plugin-parallel',
      url: 'https://cdn.example.test/episode.mp4',
      filename: 'episode.mp4',
      group: kLogicalDownloadGroup,
      updates: Updates.statusAndProgress,
      allowPause: true,
    );

    final task = buildPluginTransportTask(
      template: template,
      connections: 8,
    );

    expect(task, isA<ParallelDownloadTask>());
    final parallel = task as ParallelDownloadTask;
    expect(parallel.chunks, 8);
    expect(parallel.taskId, template.taskId);
    expect(parallel.group, kLogicalDownloadGroup);
    expect(parallel.taskId, isNot(contains('.part.')));
    expect(parallel.group, isNot(kPersistentDownloadChunkGroup));
  });

  test('fresh parallel start is selected by policy before legacy multipart', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();

    expect(source, contains("import 'download_transport_policy.dart';"));
    expect(source, contains('bool pluginParallelAccepted = false'));
    expect(source, contains('_pluginParallelAccepted = pluginParallelAccepted'));

    final start = source.indexOf('Future<bool> _enqueueTransfer(');
    final end = source.indexOf(
      'Future<DownloadResourceFingerprint?> _probeResourceFingerprint(',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('final legacySessionExists = await _parallel.restore(task);'));
    expect(body, contains('selectDownloadExecutionBackend('));
    expect(body, contains('pluginParallelAccepted: _pluginParallelAccepted'));
    expect(body, contains('legacySessionExists: legacySessionExists'));
    expect(body, contains('DownloadExecutionBackend.pluginParallel'));
    expect(body, contains('_nativeTransport.start(task)'));
    expect(body, contains('_parallel.start(task, totalBytes)'));
  });

  test('plugin parallel resume never imports plugin chunks into legacy .part state', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<bool> _resumeDownloadTask(');
    final end = source.indexOf(
      'Future<bool> _resumeUsingPartialFile(',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    expect(body, contains('selectDownloadExecutionBackend('));
    expect(body, contains('pluginParallelAccepted: _pluginParallelAccepted'));
    expect(body, contains('DownloadExecutionBackend.pluginParallel'));
    expect(body, contains('_nativeTransport.resume(task)'));

    final pluginBranch = body.indexOf('DownloadExecutionBackend.pluginParallel');
    final legacyImport = body.indexOf('_parallel.importLegacy(task, data.data)');
    expect(pluginBranch, greaterThanOrEqualTo(0));
    expect(legacyImport, greaterThan(pluginBranch));
  });
}
