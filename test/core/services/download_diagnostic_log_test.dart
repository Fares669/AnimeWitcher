import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_diagnostic_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('samples hot progress but never suppresses a terminal event', () async {
    final directory = await Directory.systemTemp.createTemp(
      'animewitcher-download-log-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final log = DownloadDiagnosticLog(() async => directory);
    await log.configure(true);
    log.record('chunk.update', {'taskId': 'episode.part.0', 'progress': 0.1});
    log.record('chunk.update', {'taskId': 'episode.part.0', 'progress': 0.2});
    log.record('chunk.update', {'taskId': 'episode.part.0', 'progress': 0.3});
    log.record('chunk.update', {
      'taskId': 'episode.part.0',
      'progress': 1.0,
      'result': true,
    });
    await log.flush();

    final rows = <Map<String, dynamic>>[];
    for (final file in await log.listFiles()) {
      for (final line in await file.readAsLines()) {
        final decoded = jsonDecode(line);
        if (decoded is Map) rows.add(Map<String, dynamic>.from(decoded));
      }
    }
    final progressRows = rows
        .where((row) => row['event'] == 'chunk.update')
        .toList(growable: false);
    expect(progressRows, hasLength(2));
    expect(progressRows.first['progress'], 0.1);
    expect(progressRows.last['result'], isTrue);
  });

  test('retains deep child and checkpoint fields', () async {
    final directory = await Directory.systemTemp.createTemp(
      'animewitcher-download-deep-log-',
    );
    addTearDown(() async {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final log = DownloadDiagnosticLog(() async => directory);
    await log.configure(true);
    log.record('parallel.childState', {
      'taskId': 'parent',
      'childTaskId': 'parent.part.0',
      'attemptGeneration': 3,
      'durableBytes': 1048576,
      'checkpointSequence': 7,
      'previousStatus': 'enqueued',
      'status': 'running',
      'freeBytes': 9999999,
    });
    await log.flush();

    final rows = <Map<String, dynamic>>[];
    for (final file in await log.listFiles()) {
      for (final line in await file.readAsLines()) {
        final decoded = jsonDecode(line);
        if (decoded is Map) rows.add(Map<String, dynamic>.from(decoded));
      }
    }
    final row = rows.lastWhere((row) => row['event'] == 'parallel.childState');
    expect(row['childTaskId'], 'parent.part.0');
    expect(row['attemptGeneration'], 3);
    expect(row['durableBytes'], 1048576);
    expect(row['checkpointSequence'], 7);
    expect(row['previousStatus'], 'enqueued');
    expect(row['freeBytes'], 9999999);
  });
}
