import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/network/next_airing_timeout.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';

void main() {
  test('next-airing fetch timeout is two seconds', () {
    expect(nextAiringFetchTimeout, const Duration(seconds: 2));
  });

  test('details shell is ready without waiting for next-airing', () {
    const ready = DetailsState(
      basicDetailsResolved: true,
      nextAiringResolved: false,
    );
    const blocked = DetailsState(
      basicDetailsResolved: false,
      nextAiringResolved: true,
    );

    expect(ready.isShellReady, isTrue);
    expect(blocked.isShellReady, isFalse);
  });

  test('awaitWithTimeout returns a fast result', () async {
    final airing = NextAiring(episode: 12, unixTime: 1_700_000_000);
    final result = await awaitWithTimeout(
      Future<NextAiring?>.value(airing),
      timeout: const Duration(milliseconds: 50),
    );
    expect(result, same(airing));
  });

  test('awaitWithTimeout returns null instead of hanging', () async {
    final never = Completer<NextAiring?>();
    final stopwatch = Stopwatch()..start();
    final result = await awaitWithTimeout(
      never.future,
      timeout: const Duration(milliseconds: 40),
    );
    stopwatch.stop();

    expect(result, isNull);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 400)));
    expect(never.isCompleted, isFalse);
  });
}
