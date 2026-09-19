import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native cancel keeps tracking until independent ownership proof', () {
    final source = File('lib/core/services/download_transport.dart')
        .readAsStringSync();
    final classStart = source.indexOf(
      'class NativeSingleDownloadTransport implements DownloadTransport',
    );
    final start = source.indexOf(
      'Future<DownloadCancelSettlement> cancel(',
      classStart,
    );
    final end = source.indexOf('\n  void forget(', start);
    expect(classStart, greaterThanOrEqualTo(0));
    expect(start, greaterThan(classStart));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);
    expect(body, isNot(contains('_detach(task.taskId)')));
    expect(body, contains('resolveDownloadCancelCommand('));
    expect(body, contains('hadTrackedOwner: transfer != null'));
    expect(body, contains('commandSucceeded: canceled'));
    expect(body, contains('commandThrew: true'));
  });
}
