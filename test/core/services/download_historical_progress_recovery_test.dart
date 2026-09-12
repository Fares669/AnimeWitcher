import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('multipart resume never treats historical percentage as durable bytes', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    final start = source.indexOf('Future<bool> _resumeDownloadTask(DownloadTask task)');
    final end = source.indexOf('Future<bool> _resumeUsingPartialFile(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);
    final parallel = body.indexOf('if (task is ParallelDownloadTask)');
    final native = body.indexOf('// A refreshed signed URL', parallel);
    expect(parallel, greaterThanOrEqualTo(0));
    expect(native, greaterThan(parallel));
    final parallelBody = body.substring(parallel, native);

    expect(parallelBody, isNot(contains('saved.progress > 0 ||')));
    expect(parallelBody, contains('if (saved.partialBytes > 0) return false;'));
    expect(parallelBody, contains('return _enqueueTransfer(task, saved.totalSize);'));
  });
}
