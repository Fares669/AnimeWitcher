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
}
