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
            body: SettingsTile(
              icon: Icons.settings,
              title: 'الإعداد',
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });
}
