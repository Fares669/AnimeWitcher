import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/adult_content_warning.dart';
import 'package:animewitcher/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _heading = 'الحلقة القادمة بعد';
const _story = 'قصة الأنمي';
const _units = <String, String>{
  'days': 'يوم',
  'hours': 'ساعة',
  'minutes': 'دقيقة',
  'seconds': 'ثانية',
};

Widget _details(int unixTime, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: Scaffold(
      body: Center(
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: SizedBox(
            width: 362,
            child: DetailsCountdownAndStory(
              item: MultimediaItem(
                title: 'أنمي دون اتصال',
                url: 'https://fixtures.invalid/countdown',
                posterUrl: '',
                nextAiring: NextAiring(episode: 7, unixTime: unixTime),
              ),
              showRatings: false,
              storyCard: const Text(_story),
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _card(String unit) => find.byKey(ValueKey('countdown-$unit'));

Finder _label(String unit) =>
    find.descendant(of: _card(unit), matching: find.text(_units[unit]!));

Finder _number(String unit) => find.descendant(
  of: _card(unit),
  matching: find.byWidgetPredicate(
    (w) => w is Text && int.tryParse(w.data ?? '') != null,
  ),
);

int _unixTime(Duration offset) =>
    DateTime.now().add(offset).millisecondsSinceEpoch ~/ 1000;

void main() {
  testWidgets('keeps Details heading, slots and labels on an ordinary tick', (
    tester,
  ) async {
    final deadline = _unixTime(
      const Duration(days: 2, hours: 3, minutes: 45, seconds: 41),
    );
    await tester.pumpWidget(_details(deadline));

    final layout = find.descendant(
      of: find.byType(NextAiringWidget),
      matching: find.byType(LayoutBuilder),
    );
    final stable = <Finder>[
      find.text(_heading),
      layout,
      for (final unit in _units.keys) ...[_card(unit), _label(unit)],
      for (final unit in ['days', 'hours', 'minutes']) _number(unit),
    ];
    final snapshots = stable.map(tester.widget).toList();
    final seconds = _number('seconds');
    final previous = int.parse(tester.widget<Text>(seconds).data!);

    // The widget test's pump drives periodic timers, but countdown values
    // read the wall clock. Ensure the sampled second has actually advanced.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    await tester.pump(const Duration(seconds: 1));

    final current = int.parse(tester.widget<Text>(seconds).data!);
    expect(current, lessThan(previous));
    for (var index = 0; index < stable.length; index++) {
      expect(tester.widget(stable[index]), same(snapshots[index]));
    }
    expect(
      tester.getTopLeft(find.text(_story)).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(_card('seconds')).dy),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('restarts a replaced deadline and retains centered RTL cards', (
    tester,
  ) async {
    await tester.pumpWidget(_details(0));
    expect(find.text(_heading), findsNothing);

    final first = _unixTime(const Duration(minutes: 5, seconds: 30));
    await tester.pumpWidget(_details(first));
    expect(find.text(_heading), findsOneWidget);
    expect(_card('hours'), findsNothing);
    expect(_card('minutes'), findsOneWidget);
    expect(_card('seconds'), findsOneWidget);
    final countdown = tester.getRect(find.byType(NextAiringWidget));
    final minutes = tester.getRect(_card('minutes'));
    final seconds = tester.getRect(_card('seconds'));
    expect(seconds.left - minutes.right, closeTo(8, 0.01));
    expect(
      (minutes.left + seconds.right) / 2,
      closeTo(countdown.center.dx, 0.01),
    );

    final future = _unixTime(
      const Duration(days: 2, hours: 3, minutes: 4, seconds: 30),
    );
    await tester.pumpWidget(_details(future, brightness: Brightness.dark));
    await tester.pump(const Duration(milliseconds: 250));
    for (final (unit, n) in [('days', '2'), ('hours', '3'), ('minutes', '4')]) {
      final value = tester.widget<Text>(_number(unit));
      final theme = Theme.of(tester.element(_card(unit)));
      expect(value.data, n);
      expect(value.textDirection, TextDirection.ltr);
      expect(value.style?.color, theme.textTheme.headlineSmall?.color);
      expect(theme.brightness, Brightness.dark);
    }

    final expired = _unixTime(const Duration(minutes: -10));
    await tester.pumpWidget(_details(expired, brightness: Brightness.dark));
    for (final unit in _units.keys) {
      expect(_card(unit), findsNothing);
    }
    expect(find.text('تُعرض الآن'), findsOneWidget);

    final upcoming = _unixTime(const Duration(seconds: 30));
    await tester.pumpWidget(_details(upcoming, brightness: Brightness.dark));
    expect(find.text('تُعرض الآن'), findsNothing);
    expect(_card('seconds'), findsOneWidget);
    expect(
      tester.getCenter(_card('seconds')).dx,
      closeTo(tester.getCenter(find.byType(NextAiringWidget)).dx, 0.01),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}
