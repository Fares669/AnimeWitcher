import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_diagnostic_log.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<Map<String, dynamic>>> _readRows(DownloadDiagnosticLog log) async {
  await log.flush();
  final rows = <Map<String, dynamic>>[];
  for (final file in await log.listFiles()) {
    for (final line in await file.readAsLines()) {
      final decoded = jsonDecode(line);
      if (decoded is Map) rows.add(Map<String, dynamic>.from(decoded));
    }
  }
  return rows;
}

void main() {
  test(
    'multipart diagnostic progress is sampled once per logical parent',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'animewitcher-download-thermal-log-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      final log = DownloadDiagnosticLog(() async => directory);
      await log.configure(true);
      for (var index = 0; index < 16; index++) {
        log.record('chunk.update', {
          'taskId': 'episode.part.$index',
          'parentTaskId': 'episode',
          'progress': 0.1,
        });
      }

      final rows = await _readRows(log);
      final progressRows = rows
          .where((row) => row['event'] == 'chunk.update')
          .toList(growable: false);
      expect(progressRows, hasLength(1));
      expect(progressRows.single['parentTaskId'], 'episode');
    },
  );

  test(
    'plugin child progress without parent metadata is sampled by inferred parent',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'animewitcher-download-plugin-log-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      final log = DownloadDiagnosticLog(() async => directory);
      await log.configure(true);
      for (var index = 0; index < 16; index++) {
        log.record('task.update', {
          'taskId': 'episode.part.$index',
          'progress': 0.1,
        });
      }

      final rows = await _readRows(log);
      final progressRows = rows
          .where((row) => row['event'] == 'task.update')
          .toList(growable: false);
      expect(progressRows, hasLength(1));
    },
  );

  test('Dart progress journal does not request fsync on every sample', () {
    final source = File('lib/core/services/download_diagnostic_log.dart')
        .readAsStringSync();
    expect(source, isNot(contains('flush: true')));
  });

  test('iOS progress hot paths do not force synchronous disk flushes', () {
    final swift = File('ios/Runner/DownloadNativeWaitingQueue.swift')
        .readAsStringSync();

    final saveStart = swift.indexOf('private static func saveLocked(');
    final saveEnd = swift.indexOf('private static func unique(', saveStart);
    expect(saveStart, greaterThanOrEqualTo(0));
    expect(saveEnd, greaterThan(saveStart));
    final saveSection = swift.substring(saveStart, saveEnd);
    expect(saveSection, isNot(contains('UserDefaults.standard.synchronize()')));

    final loggerStart = swift.indexOf('enum DownloadNativeDiagnosticLog');
    final loggerEnd = swift.indexOf('import ObjectiveC', loggerStart);
    expect(loggerStart, greaterThanOrEqualTo(0));
    expect(loggerEnd, greaterThan(loggerStart));
    final loggerSection = swift.substring(loggerStart, loggerEnd);
    expect(
      loggerSection,
      contains('if event != "progress" { try handle.synchronize() }'),
    );
  });

  test(
    'multipart background refill probes run on ownership changes, not every byte callback',
    () {
      final swift = File('ios/Runner/DownloadNativeWaitingQueue.swift')
          .readAsStringSync();
      final start = swift.indexOf('static func handleBytesWritten(');
      final end = swift.indexOf('private static func postSingleTaskUpdate(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final writeHandler = swift.substring(start, end);
      final multipartStart = writeHandler.indexOf(
        'if isDownloadPart(downloadTask) {',
      );
      final multipartEnd = writeHandler.indexOf(
        'guard let id = taskId(from: downloadTask)',
        multipartStart,
      );
      expect(multipartStart, greaterThanOrEqualTo(0));
      expect(multipartEnd, greaterThan(multipartStart));
      final multipartProgress = writeHandler.substring(
        multipartStart,
        multipartEnd,
      );
      expect(
        multipartProgress,
        isNot(contains('promoteMultipartIfPossible(')),
      );

      final completionStart = swift.indexOf(
        'static func handlePluginTaskCompleted(',
      );
      final completionEnd = swift.indexOf(
        'static func parkFailedTask(',
        completionStart,
      );
      expect(completionStart, greaterThanOrEqualTo(0));
      expect(completionEnd, greaterThan(completionStart));
      final completion = swift.substring(completionStart, completionEnd);
      expect(completion, contains('promoteMultipartIfPossible('));
    },
  );
}
