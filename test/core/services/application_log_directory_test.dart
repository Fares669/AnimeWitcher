import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/application_log_directory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('coalesces concurrent reads and refreshes a moved folder', () async {
    var now = Duration.zero;
    var calls = 0;
    final first = Completer<Directory>();
    final cache = ShortLivedLogDirectory(
      elapsed: () => now,
      resolve: () {
        calls++;
        return calls == 1
            ? first.future
            : Future.value(Directory('/new-documents/log'));
      },
    );

    final startup = cache.get();
    expect(cache.get(), same(startup));
    expect(calls, 1);
    now = const Duration(seconds: 5); // The first lookup is still in flight.
    expect(cache.get(), same(startup));
    first.complete(Directory('/original-documents/log'));
    expect((await startup).path, '/original-documents/log');

    now = const Duration(milliseconds: 6999);
    expect((await cache.get()).path, '/original-documents/log');
    expect(calls, 1);

    // Reading a fresh result must not silently extend the interval.
    now = const Duration(seconds: 7);
    expect((await cache.get()).path, '/new-documents/log');
    expect(calls, 2);
  });

  test('a failed lookup never poisons later diagnostic entries', () async {
    var calls = 0;
    final cache = ShortLivedLogDirectory(
      elapsed: () => Duration.zero,
      resolve: () {
        calls++;
        if (calls == 1) throw const FileSystemException('unavailable');
        if (calls == 2) {
          return Future.error(const FileSystemException('not ready'));
        }
        return Future.value(Directory('/available-documents/log'));
      },
    );
    await expectLater(cache.get(), throwsA(isA<FileSystemException>()));
    await expectLater(cache.get(), throwsA(isA<FileSystemException>()));
    expect((await cache.get()).path, '/available-documents/log');
    expect(calls, 3);
  });
}
