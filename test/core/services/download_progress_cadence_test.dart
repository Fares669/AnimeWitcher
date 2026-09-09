import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('multipart parent progress is coalesced to one second', () {
    expect(kParallelProgressCoalesceDelay, const Duration(seconds: 1));
  });

  test(
    'active child progress is checkpointed instead of fsynced per callback',
    () {
      final source = File('lib/core/services/persistent_parallel_download.dart')
          .readAsStringSync();

      expect(source, contains('bool aggregatePersistDirty = false;'));
      expect(
        source,
        contains(
          '_scheduleAggregateProgress(session, persist: progressChanged);',
        ),
      );
      expect(
        source,
        contains('if (persistCheckpoint) await _persist(session);'),
      );
    },
  );

  test(
    'iOS download bridges and system overlay are rate limited to one second',
    () {
      final queue = File('ios/Runner/DownloadNativeWaitingQueue.swift')
          .readAsStringSync();
      final manager = File(
        'ios/Runner/DownloadContinuedProcessingManager.swift',
      ).readAsStringSync();

      expect(queue, contains('chunkBridgeInterval: CFTimeInterval = 1.0'));
      expect(queue, contains('taskBridgeInterval: CFTimeInterval = 1.0'));
      expect(queue, contains('now - previous < 1.0'));
      expect(manager, contains('minimumUpdateInterval: TimeInterval = 1.0'));
      expect(manager, contains('applyIfDue(snapshot, to: task)'));
    },
  );
}
