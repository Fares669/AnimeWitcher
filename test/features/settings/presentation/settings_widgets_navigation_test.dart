import 'package:animewitcher/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings navigation chevron points left in RTL', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: SettingsTile(icon: Icons.settings, title: 'الإعداد'),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('short descriptions stay below the title and keep the action', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: SettingsTile(
              icon: Icons.alternate_email_rounded,
              title: 'تغيير البريد الإلكتروني',
              subtitle: 'يجب التحقق من البريد الجديد',
              subtitleIsDescription: true,
              onTap: () => opened = true,
            ),
          ),
        ),
      ),
    );

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.subtitle, isNotNull);
    expect(tile.trailing, isA<Icon>());
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    await tester.tap(find.text('تغيير البريد الإلكتروني'));
    expect(opened, isTrue);
  });

  testWidgets('short current values retain their value pill by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SettingsTile(
            icon: Icons.dark_mode_rounded,
            title: 'المظهر',
            subtitle: 'داكن',
          ),
        ),
      ),
    );

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.subtitle, isNull);
    expect(find.text('داكن'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left_rounded), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });
}
