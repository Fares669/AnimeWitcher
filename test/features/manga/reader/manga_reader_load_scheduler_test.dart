import 'dart:math' as math;

import 'package:animewitcher/features/manga/reader/widgets/manga_reader_load_scheduler.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';

final class _StockScheduleOracle {
  _StockScheduleOracle(int count, int initial, int width)
    : batches = mangaReaderOrderedPreloadBatches(
        pageCount: count,
        initialPage: initial,
        batchSize: width,
      ) {
    if (batches.isEmpty) return;
    final resume = initial.clamp(0, count - 1).toInt();
    backward = batches.indexWhere((batch) => batch.last < resume);
    forwardEnd = backward < 0 ? batches.length : backward;
    admitted.addAll(batches.first);
    if (backward >= 0) admitted.addAll(batches[backward]);
  }

  final List<List<int>> batches;
  final Set<int> admitted = <int>{};
  final Set<int> finished = <int>{};
  int forward = 0;
  int backward = -1;
  int forwardEnd = 0;
  int notifications = 0;

  void mark(int index) {
    if (batches.isEmpty || !finished.add(index)) return;
    final oldLength = admitted.length;
    while (backward >= 0 &&
        backward < batches.length &&
        batches[backward].every(finished.contains)) {
      backward++;
      if (backward < batches.length) admitted.addAll(batches[backward]);
    }
    while (forward < forwardEnd && batches[forward].every(finished.contains)) {
      forward++;
      if (forward < forwardEnd) admitted.addAll(batches[forward]);
    }
    if (admitted.length != oldLength) notifications++;
  }
}

void _checkOrderedSchedulerProperty() {
  var transitions = 0;
  for (final count in [-3, 0, 1, 2, 3, 7, 40, 120]) {
    final indexes = [for (var i = 0; i < count; i++) i];
    for (final start in {-5, 0, 1, count ~/ 2, count - 1, count + 3}) {
      for (final width in [0, 1, 2, 6, 20, 27]) {
        final streams = <List<int>>[
          indexes,
          indexes.reversed.toList(),
          [...indexes.where((i) => i.isOdd), ...indexes.where((i) => i.isEven)],
          [...indexes]..shuffle(math.Random(37)),
        ];
        for (final events in streams) {
          final expected = _StockScheduleOracle(count, start, width);
          final actual = MangaReaderLoadBatchController(
            pageCount: count,
            initialPage: start,
            batchSize: width,
          );
          final initial = actual.unlockedPages;
          final initialOrder = initial.toList();
          var notifications = 0;
          actual.addListener(() {
            notifications++;
            if (!listEquals(
              actual.unlockedPages.toList(),
              expected.admitted.toList(),
            )) {
              fail('scheduler listener emitted before applying admissions');
            }
          });
          void check(int event) {
            if (!listEquals(
                  actual.unlockedPages.toList(),
                  expected.admitted.toList(),
                ) ||
                !listEquals(initial.toList(), initialOrder) ||
                notifications != expected.notifications ||
                actual.canLoad(-1) ||
                actual.canLoad(count) ||
                actual.canLoad(count + 1) ||
                indexes.any(
                  (i) => actual.canLoad(i) != expected.admitted.contains(i),
                )) {
              fail(
                'ordered scheduler diverged count=$count start=$start width=$width event=$event',
              );
            }
          }

          try {
            check(-9);
            for (final event in [
              -1,
              count,
              count,
              ...events.expand((i) => [i, i]),
            ]) {
              expected.mark(event);
              actual.markSettled(event);
              transitions++;
              check(event);
            }
          } finally {
            actual.dispose();
          }
        }
      }
    }
  }
  final nested = MangaReaderLoadBatchController(
    pageCount: 7,
    initialPage: 0,
    batchSize: 2,
  );
  try {
    final snapshots = <List<int>>[];
    expect(() => nested.unlockedPages.add(-1), throwsUnsupportedError);
    nested.addListener(() {
      snapshots.add(nested.unlockedPages.toList());
      if (snapshots.length == 1) {
        nested.markSettled(2);
        nested.markSettled(3);
      }
    });
    nested.markSettled(0);
    nested.markSettled(1);
    expect(snapshots, [
      [0, 1, 2, 3],
      [0, 1, 2, 3, 4, 5],
    ]);
  } finally {
    nested.dispose();
  }
  expect(transitions, 52344);
}

void main() {
  test(
    'preserves ordered preload admissions, settled events, and notifications',
    _checkOrderedSchedulerProperty,
  );
}
