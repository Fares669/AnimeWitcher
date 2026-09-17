import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy iOS URLSession hook never owns V2 package tasks', () {
    final source = File(
      'ios/Runner/DownloadNativeWaitingQueue.swift',
    ).readAsStringSync();
    final compact = source.replaceAll(RegExp(r'\s+'), ' ');

    expect(
      compact,
      contains(
        'static func isV2Task(_ task: URLSessionTask) -> Bool { '
        'taskId(from: task)?.hasPrefix("aw_v2_") == true }',
      ),
    );
    expect(
      compact,
      contains('guard !isV2Task(task) else { return false }'),
    );
    expect(
      compact,
      contains(
        'DownloadNativeWaitingQueue.nativePromotionAvailable && '
        '!DownloadNativeWaitingQueue.isV2Task(task)',
      ),
    );
    expect(
      compact,
      contains(
        'DownloadNativeWaitingQueue.nativePromotionAvailable && '
        '!DownloadNativeWaitingQueue.isV2Task(downloadTask)',
      ),
    );
  });
}
