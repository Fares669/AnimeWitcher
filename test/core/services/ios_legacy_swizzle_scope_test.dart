import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  final end = source.indexOf(endMarker, start + startMarker.length);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $startMarker');
  expect(end, greaterThan(start), reason: 'missing $endMarker');
  return source.substring(start, end);
}

void main() {
  test('legacy URLSession seam never owns background_downloader plugin chunks', () {
    final source = File(
      'ios/Runner/DownloadNativeWaitingQueue.swift',
    ).readAsStringSync();

    expect(source, contains('static func isPluginDownloadChunk(_ task: URLSessionTask) -> Bool'));
    expect(source, contains('static func isLegacyDownloadPart(_ task: URLSessionTask) -> Bool'));
    expect(source, contains('return group == "chunk"'));
    expect(source, contains('return group == "animewitcher_parts"'));

    final bytes = _slice(
      source,
      'static func handleBytesWritten(',
      'static func rememberDownloadSession(',
    );
    expect(bytes, contains('if isPluginDownloadChunk(downloadTask) { return }'));
    expect(bytes, contains('if isLegacyDownloadPart(downloadTask) {'));
    expect(bytes, isNot(contains('if isDownloadPart(downloadTask) {')));

    final completion = _slice(
      source,
      'static func handlePluginTaskCompleted(',
      'static func parkFailedTask(',
    );
    final pluginReturn = completion.indexOf('if isPluginDownloadChunk(task) { return }');
    final legacyBranch = completion.indexOf('if isLegacyDownloadPart(task) {');
    final promoteNext = completion.indexOf('promoteNext(on: session)');
    expect(pluginReturn, greaterThanOrEqualTo(0));
    expect(legacyBranch, greaterThan(pluginReturn));
    expect(
      promoteNext,
      greaterThan(legacyBranch),
      reason:
          'a plugin chunk completion must return before legacy multipart or logical-episode queue promotion runs',
    );

    final chunkBridge = _slice(
      source,
      'private static func postMultipartChunkUpdate(',
      'private static func postMultipartChunkSample(',
    );
    expect(chunkBridge, contains('guard isLegacyDownloadPart(task),'));

    final retry = _slice(
      source,
      'static func retryBackgroundTransferIfNeeded(',
      'static func handlePluginTaskCompleted(',
    );
    expect(retry, contains('if isPluginDownloadChunk(task) { return false }'));
    expect(retry, contains('let multipartPart = isLegacyDownloadPart(task)'));

    final promotion = _slice(
      source,
      'static func promoteMultipartIfPossible(',
      'private static func startMultipartWaiter(',
    );
    expect(promotion, contains('isLegacyDownloadPart(task),'));

    final supported = _slice(
      source,
      'private static func postSupportedMultipartProgress(',
      'private static func handleSupportedPluginProgress(',
    );
    expect(
      supported,
      contains('task.group == "chunk" || task.group == "animewitcher_parts"'),
      reason:
          'official background_downloader callbacks remain authoritative for plugin chunks and can still observe migrated legacy children',
    );
  });
}
