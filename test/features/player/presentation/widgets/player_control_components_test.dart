import 'package:animewitcher/features/player/presentation/widgets/player_control_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void _noop() {}

void main() {
  testWidgets('player uses the same plain left back glyph as pages', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('ar'),
        home: Scaffold(
          body: PlayerTopBar(title: 'Episode', onBack: _noop),
        ),
      ),
    );

    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
  });

  testWidgets('renders the player title left-to-right', (tester) async {
    const title = 'Ore dake Level Up na Ken';
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('ar'),
        home: Scaffold(body: PlayerTopBar(title: title)),
      ),
    );

    final text = tester.widget<Text>(find.text(title));
    expect(text.textDirection, TextDirection.ltr);
    expect(text.textAlign, TextAlign.start);
  });
}
