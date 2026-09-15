import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/download_transport_policy.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uri> _backgroundDownloaderRoot() async {
  final packageConfigFile = File('.dart_tool/package_config.json');
  final packageConfig =
      jsonDecode(await packageConfigFile.readAsString()) as Map<String, dynamic>;
  final packages = (packageConfig['packages'] as List).cast<Map<String, dynamic>>();
  final package = packages.singleWhere(
    (entry) => entry['name'] == 'background_downloader',
  );
  return packageConfigFile.parent.uri.resolve(package['rootUri'] as String);
}

Future<String> _packageSource(Uri root, String path) =>
    File.fromUri(root.resolve(path)).readAsString();

void main() {
  late Uri pluginRoot;

  setUpAll(() async {
    pluginRoot = await _backgroundDownloaderRoot();
  });

  test('characterization is pinned to background_downloader 9.6.1', () async {
    final pubspec = await _packageSource(pluginRoot, 'pubspec.yaml');
    expect(pubspec, contains('version: 9.6.1'));
  });

  test('plugin parallel keeps one logical parent identity', () {
    final template = DownloadTask(
      taskId: 'episode-42',
      url: 'https://example.test/video.mp4',
      filename: 'episode-42.mp4',
      group: kLogicalDownloadGroup,
      retries: 3,
      allowPause: true,
    );

    final task = buildPluginTransportTask(template: template, connections: 8);

    expect(task, isA<ParallelDownloadTask>());
    expect(task.taskId, template.taskId);
    expect(task.group, kLogicalDownloadGroup);
    expect(task.allowPause, isTrue);
    expect(task.retries, 3);
    expect((task as ParallelDownloadTask).chunks, 8);
  });

  test('plugin owns chunk identity and failed resume cancels the parent', () async {
    final chunkSource = await _packageSource(pluginRoot, 'lib/src/chunk.dart');

    expect(chunkSource, contains('group: BaseDownloader.chunkGroup'));
    expect(chunkSource, contains("'parentTaskId': parentTask.taskId"));
    expect(
      chunkSource,
      contains('chunks.map((chunk) => FileDownloader().resume(chunk.task))'),
    );
    expect(
      chunkSource,
      contains('await FileDownloader().cancelTaskWithId(task.taskId)'),
    );
  });

  test('iOS pause cancel and retry settle all chunks through the parent', () async {
    final source = await _packageSource(
      pluginRoot,
      'ios/background_downloader/Sources/background_downloader/ParallelDownloader.swift',
    );

    final pauseStart = source.indexOf('func pauseTask() async -> Bool');
    final pauseChunks = source.indexOf('method: "pauseTasks"', pauseStart);
    final pauseResumeData = source.indexOf('method: "resumeData"', pauseStart);
    expect(pauseStart, greaterThanOrEqualTo(0));
    expect(pauseChunks, greaterThan(pauseStart));
    expect(pauseResumeData, greaterThan(pauseChunks));

    final cancelStart = source.indexOf('func cancelTask()');
    final cancelChunks = source.indexOf('cancelAllChunkTasks()', cancelStart);
    final canceledParent = source.indexOf(
      'finishTask(status: .canceled)',
      cancelStart,
    );
    expect(cancelStart, greaterThanOrEqualTo(0));
    expect(cancelChunks, greaterThan(cancelStart));
    expect(canceledParent, greaterThan(cancelChunks));

    expect(source, contains('status == .failed && chunk.task.retriesRemaining > 0'));
    expect(source, contains('method: "enqueueChild"'));
    expect(source, contains('cancelAllChunkTasks()'));
  });

  test('Android pause stop and retry settle child writers', () async {
    final source = await _packageSource(
      pluginRoot,
      'android/src/main/kotlin/com/bbflight/background_downloader/ParallelDownloadTaskRunner.kt',
    );

    final pauseSignal = source.indexOf('BDPlugin.pausedTaskIds.remove(task.taskId)');
    final pauseChunks = source.indexOf('pauseAllChunkTasks()', pauseSignal);
    final parentResumeData = source.indexOf('"resumeData"', pauseChunks);
    final parentPaused = source.indexOf(
      'parallelTaskStatusUpdateCompleter.complete(TaskStatus.paused)',
      parentResumeData,
    );
    expect(pauseSignal, greaterThanOrEqualTo(0));
    expect(pauseChunks, greaterThan(pauseSignal));
    expect(parentResumeData, greaterThan(pauseChunks));
    expect(parentPaused, greaterThan(parentResumeData));

    final stopped = source.indexOf('if (context.isTaskStopped)');
    final stopCancel = source.indexOf('cancelAllChunkTasks()', stopped);
    expect(stopped, greaterThanOrEqualTo(0));
    expect(stopCancel, greaterThan(stopped));

    expect(
      source,
      contains('status == TaskStatus.failed && chunkTask.retriesRemaining > 0'),
    );
    expect(source, contains('"enqueueChild"'));
  });

  test('platform capability stays closed without device kill/relaunch evidence', () {
    for (final platform in TargetPlatform.values) {
      expect(
        pluginParallelAcceptedForPlatform(platform),
        isFalse,
        reason: '$platform must remain disabled until platform acceptance passes',
      );
    }
  });
}
