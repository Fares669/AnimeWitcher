import 'dart:async';

import 'package:animewitcher/core/network/poster_warm_queue.dart';
import 'package:flutter_test/flutter_test.dart';

String _url(int n) => 'https://example.test/$n';

void main() {
  test('all batches share three slots and dispatch FIFO through failures', () async {
    final fetches = _Fetches();
    final queue = PosterWarmQueue(
      fetch: fetches.fetch,
      isBlocked: (_) => false,
    );

    queue.enqueue(['', 'invalid', ' ${_url(0)} ', _url(1), _url(2), _url(3)]);
    queue.enqueue([_url(0), _url(3), _url(4), _url(5)], limit: 1);
    expect(fetches.started, List.generate(3, _url));

    await fetches.finish(_url(1), failed: true);
    expect(fetches.started, List.generate(4, _url));
    await fetches.finish(_url(0));
    expect(fetches.started, List.generate(5, _url));
    await fetches.drain();

    // Failed speculative URLs, like successful ones, are only attempted once;
    // the display path handles retries. The unaccepted URL can be added later.
    queue.enqueue([_url(1), _url(4), _url(5)]);
    await fetches.drain();
    expect(fetches.started, List.generate(6, _url));
    expect(fetches.peak, 3);
  });

  test('caps the waiting list at 72 without warming discarded URLs', () async {
    final fetches = _Fetches();
    final queue = PosterWarmQueue(
      fetch: fetches.fetch,
      isBlocked: (_) => false,
    );

    queue.enqueue(List.generate(80, _url), limit: 80);
    expect(fetches.started, List.generate(3, _url));
    await fetches.finish(_url(0));
    queue.enqueue([_url(3), _url(74), _url(75)]);
    await fetches.drain();

    // Three active plus 72 pending were accepted. The first discarded URL
    // was accepted when the next batch found room, and ran at the FIFO tail.
    expect(fetches.started, List.generate(76, _url));
    expect(fetches.peak, 3);
  });

  test('checks blocked hosts both at admission and before fetch', () async {
    final fetches = _Fetches();
    final blocked = {_url(4)};
    final queue = PosterWarmQueue(
      fetch: fetches.fetch,
      isBlocked: blocked.contains,
    );
    queue.enqueue(List.generate(6, _url));
    blocked.add(_url(3));
    await fetches.finish(_url(0));
    expect(fetches.started, [_url(0), _url(1), _url(2), _url(5)]);
    await fetches.drain();

    blocked.clear();
    queue.enqueue([_url(3), _url(4)]);
    await fetches.drain();
    expect(fetches.started, [
      _url(0),
      _url(1),
      _url(2),
      _url(5),
      _url(3),
      _url(4),
    ]);
  });
}

final class _Fetches {
  final started = <String>[];
  final active = <String, Completer<void>>{};
  var peak = 0;

  Future<void> fetch(String url) {
    started.add(url);
    final completion = Completer<void>();
    active[url] = completion;
    if (active.length > peak) peak = active.length;
    return completion.future;
  }

  Future<void> finish(String url, {bool failed = false}) async {
    final completion = active.remove(url)!;
    if (failed) {
      completion.completeError(StateError('simulated fetch failure'));
    } else {
      completion.complete();
    }
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> drain() async {
    while (active.isNotEmpty) {
      await finish(active.keys.first);
    }
  }
}
