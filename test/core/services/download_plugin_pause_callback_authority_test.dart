import 'dart:io';

import 'package:animewitcher/core/services/background_downloader_transport.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paused Transfer handle is not live writer ownership', () {
    expect(runtimeTaskStatusCanOwnWriter(TaskStatus.running), isTrue);
    expect(runtimeTaskStatusCanOwnWriter(TaskStatus.enqueued), isTrue);
    expect(runtimeTaskStatusCanOwnWriter(TaskStatus.waitingToRetry), isTrue);
    expect(runtimeTaskStatusCanOwnWriter(TaskStatus.paused), isFalse);
    expect(runtimeTaskStatusCanOwnWriter(TaskStatus.failed), isFalse);
    expect(runtimeTaskStatusCanOwnWriter(TaskStatus.canceled), isFalse);
    expect(runtimeTaskStatusCanOwnWriter(TaskStatus.complete), isFalse);
  });

  test('paused callback guard uses runtime writer status, not handle presence', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf(
      '// A delayed pause acknowledgement from an earlier control generation',
    );
    final end = source.indexOf('_updatesController.add(update);', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final guard = source.substring(start, end);

    expect(
      guard,
      contains('_nativeTransport.runtimeStatusCanOwnWriter(update.task.taskId)'),
    );
    expect(
      guard,
      isNot(contains('_nativeTransport.owns(update.task.taskId)')),
      reason: 'a retained paused Transfer handle must not swallow the real pause callback',
    );
  });
}
