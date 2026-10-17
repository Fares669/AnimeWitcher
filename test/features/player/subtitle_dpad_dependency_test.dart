import 'package:animewitcher/features/player/presentation/widgets/subtitle_appearance_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('subtitle D-pad button selects once with a remote and a tap', (
    tester,
  ) async {
    var selections = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DpadButton(label: 'Apply', onPressed: () => selections++),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selections, 1);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(selections, 2);
  });

  testWidgets('subtitle color circle keeps its touch selection behavior', (
    tester,
  ) async {
    var selections = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            child: DpadColorCircle(
              colorValue: 0xffffffff,
              isSelected: true,
              onTap: () => selections++,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();
    expect(selections, 1);
  });
}
