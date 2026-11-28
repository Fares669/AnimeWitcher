import 'package:animewitcher/shared/widgets/poster_plate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a title always gets the same colour, and titles differ', () {
    expect(PosterPlate.hueOf('Frieren'), PosterPlate.hueOf('Frieren'));
    expect(PosterPlate.hueOf('Frieren'), isNot(PosterPlate.hueOf('Naruto')));
    expect(PosterPlate.hueOf(''), 0);
    // A long title wraps the hash rather than overflowing it.
    final long = PosterPlate.hueOf('x' * 5000);
    expect(long, inInclusiveRange(0, 359));
  });

  test('retries wait 1.2 s and double, five times, then rest', () {
    final policy = PosterRetryPolicy.instance;
    expect(policy.delayFor(0), const Duration(milliseconds: 1200));
    expect(policy.delayFor(1), const Duration(milliseconds: 2400));
    expect(policy.delayFor(4), const Duration(milliseconds: 19200));
    expect(policy.delayFor(5), isNull);

    const url = 'https://example.test/poster.jpg';
    final now = DateTime(2026, 10, 2, 12);
    expect(policy.canRetry(url, 0), isTrue);
    policy.cool(url, now);
    expect(policy.isCooling(url, now.add(const Duration(minutes: 9))), isTrue);
    expect(
      policy.isCooling(url, now.add(const Duration(minutes: 11))),
      isFalse,
    );
    policy.clear(url);
  });

  test(
    'poster cooling history forgets only the oldest URLs under pressure',
    () {
      final policy = PosterRetryPolicy.instance;
      final now = DateTime(2026, 10, 8);
      final urls = List.generate(2048, (i) => 'https://example.test/outage/$i');
      addTearDown(() {
        for (final url in urls) {
          policy.clear(url);
        }
      });
      for (final url in urls) {
        policy.cool(url, now);
      }
      expect(policy.isCooling(urls.first, now), isFalse);
      expect(policy.isCooling(urls.last, now), isTrue);
      expect(
        policy.isCooling(urls.last, now.add(const Duration(minutes: 9))),
        isTrue,
      );
    },
  );

  test('new cooling activity releases unrelated expired URLs', () {
    final policy = PosterRetryPolicy.instance;
    final now = DateTime(2026, 10, 9);
    const expired = 'https://example.test/expired-poster';
    const recent = 'https://example.test/recent-poster';
    addTearDown(() {
      policy.clear(expired);
      policy.clear(recent);
    });
    policy.cool(expired, now);
    policy.cool(recent, now.add(PosterRetryPolicy.cooldown));
    // Ask at the old timestamp to distinguish physical removal from the
    // lookup's original lazy "still stored but expired" behavior.
    expect(policy.isCooling(expired, now), isFalse);
    expect(
      policy.isCooling(recent, now.add(PosterRetryPolicy.cooldown)),
      isTrue,
    );
  });

  testWidgets('the plate fills its card', (tester) async {
    await tester.pumpWidget(
      const Center(
        child: SizedBox(
          width: 120,
          height: 180,
          child: PosterPlate(seed: 'Frieren'),
        ),
      ),
    );
    expect(tester.getSize(find.byType(PosterPlate)), const Size(120, 180));
    expect(tester.takeException(), isNull);
  });

  testWidgets('same hue reuses immutable decorations across builds', (
    tester,
  ) async {
    Future<List<Decoration>> pumpPlate(String seed) async {
      await tester.pumpWidget(
        Center(
          child: SizedBox(
            width: 120,
            height: 180,
            child: PosterPlate(seed: seed),
          ),
        ),
      );
      return tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(PosterPlate),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((widget) => widget.decoration)
          .toList();
    }

    final first = await pumpPlate('Frieren');
    expect(first, hasLength(3));
    final repeated = await pumpPlate('Frieren');
    for (var i = 0; i < first.length; i++) {
      expect(repeated[i], same(first[i]));
    }
    final different = await pumpPlate('Naruto');
    expect(different[0], isNot(same(first[0])));
  });
}
