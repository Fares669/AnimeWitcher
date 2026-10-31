import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/utils/offset_pager.dart';

void main() {
  OffsetPager<String> pager({bool stopOnEmptyPage = false}) =>
      OffsetPager<String>(
        keyOf: (item) => item,
        stopOnEmptyPage: stopOnEmptyPage,
      );

  test('appends deduped items and advances the offset', () async {
    final p = pager();
    await p.loadNext((offset) async {
      expect(offset, 0);
      return (items: ['a', 'b'], nextOffset: 2, hasMore: true);
    });
    await p.loadNext((offset) async {
      expect(offset, 2);
      return (items: ['b', 'c'], nextOffset: 3, hasMore: false);
    });
    expect(p.items, ['a', 'b', 'c']);
    expect(p.hasMore, isFalse);
    expect(p.loading, isFalse);
    expect(p.error, isNull);
  });

  test('records the error and keeps hasMore for a retry', () async {
    final p = pager();
    await p.loadNext((offset) async => throw StateError('boom'));
    expect(p.error, isA<StateError>());
    expect(p.hasMore, isTrue);
    expect(p.loading, isFalse);
  });

  test('an empty page stops paging only when asked', () async {
    final strict = pager(stopOnEmptyPage: true);
    await strict.loadNext(
      (offset) async => (items: <String>[], nextOffset: 5, hasMore: true),
    );
    expect(strict.hasMore, isFalse);

    final lax = pager();
    await lax.loadNext(
      (offset) async => (items: <String>[], nextOffset: 5, hasMore: true),
    );
    expect(lax.hasMore, isTrue);
    expect(lax.offset, 5);
  });

  test('reset restores the initial state', () async {
    final p = pager();
    await p.loadNext(
      (offset) async => (items: ['a'], nextOffset: 1, hasMore: false),
    );
    p.reset();
    expect(p.items, isEmpty);
    expect(p.offset, 0);
    expect(p.hasMore, isTrue);
  });
}
