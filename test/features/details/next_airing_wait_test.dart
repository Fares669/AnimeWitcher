import 'package:animewitcher/features/details/presentation/widgets/next_airing_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wait is said in the largest unit that still has a whole number in it:
/// six days, then five, then — inside a day — hours, then minutes.
void main() {
  late BuildContext ctx;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }

  String ar(Duration d) => formatNextAiringWait(ctx, d);

  testWidgets('days, while there is more than one left', (tester) async {
    await pump(tester);
    expect(ar(const Duration(days: 6, hours: 3)), '6 أيام');
    expect(ar(const Duration(days: 1, hours: 2)), 'يوم');
    expect(ar(const Duration(days: 6)), '6 أيام');
    expect(ar(const Duration(days: 1, hours: 5)), 'يوم');
    expect(ar(const Duration(days: 2, hours: 5)), 'يومين');
    expect(ar(const Duration(days: 11)), '11 يومًا');
  });

  testWidgets('hours, once it is under a day', (tester) async {
    await pump(tester);
    expect(ar(const Duration(hours: 18, minutes: 40)), '18 ساعة');
    expect(ar(const Duration(hours: 18)), '18 ساعة');
    expect(ar(const Duration(hours: 2, minutes: 10)), 'ساعتين');
    // 23:59 is still hours, not "a day".
    expect(ar(const Duration(hours: 23, minutes: 59)), '23 ساعة');
  });

  testWidgets('minutes, in the last hour', (tester) async {
    await pump(tester);
    expect(ar(const Duration(minutes: 40)), '40 دقيقة');
    expect(ar(const Duration(minutes: 3)), '3 دقائق');
    expect(ar(const Duration(seconds: 30)), 'أقل من دقيقة');
    expect(ar(Duration.zero), 'الآن');
  });
}
