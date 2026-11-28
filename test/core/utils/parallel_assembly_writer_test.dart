import 'dart:io';

import 'package:animewitcher/core/utils/parallel_assembly_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workers are limited to one and an error does not hold the lease', () async {
    final directory = await Directory.systemTemp.createTemp('assembly-lease-');
    final first = File('${directory.path}/first');
    final second = File('${directory.path}/second');
    final input = File('${directory.path}/range');
    try {
      final writer = (await ParallelAssemblyWriter.tryOpen(first.path, 3, 2))!;
      try {
        // A sibling assembly must retain the original path, without opening or
        // truncating its staging file in this worker.
        await second.writeAsBytes([9, 8, 7]);
        expect(await ParallelAssemblyWriter.tryOpen(second.path, 3, 2), isNull);
        expect(await second.readAsBytes(), [9, 8, 7]);

        // The exact filesystem error is propagated, not treated as EOF.
        await expectLater(
          writer.copy(input.path, 3),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await writer.close();
      }
      // The failed writer released its fd before cleanup/retry.
      await first.delete();
      await input.writeAsBytes([3, 2, 1]);
      final retry = (await ParallelAssemblyWriter.tryOpen(first.path, 3, 2))!;
      try {
        expect(await retry.copy(input.path, 3), isTrue);
        await retry.flush();
      } finally {
        await retry.close();
      }
      expect(await first.readAsBytes(), [3, 2, 1]);
      expect(await second.readAsBytes(), [9, 8, 7]);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('failure to create staging releases the worker budget', () async {
    final directory = await Directory.systemTemp.createTemp('assembly-init-');
    try {
      await expectLater(
        ParallelAssemblyWriter.tryOpen('${directory.path}/absent/output', 2, 1),
        throwsA(isA<FileSystemException>()),
      );
      final output = File('${directory.path}/output');
      final writer = (await ParallelAssemblyWriter.tryOpen(output.path, 2, 1))!;
      await writer.close();
      expect(await output.length(), 2);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
