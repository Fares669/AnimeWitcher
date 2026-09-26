import 'package:animewitcher/features/manga/reader/widgets/manga_zoomable_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<bool> turns;
  late TransformationController transform;

  Future<Offset> pump(WidgetTester tester) async {
    turns = <bool>[];
    transform = TransformationController();
    addTearDown(transform.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MangaZoomablePage(
          transformationController: transform,
          onWheelPage: turns.add,
          child: const ColoredBox(
            color: Colors.white,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
    return tester.getCenter(find.byType(MangaZoomablePage));
  }

  testWidgets('a plain wheel turns the page and does not zoom', (tester) async {
    final center = await pump(tester);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(center));

    await tester.sendEventToBinding(
      mouse.scroll(const Offset(0, 60), timeStamp: const Duration(seconds: 1)),
    );
    await tester.pump();

    expect(turns, <bool>[true]);
    expect(transform.value.getMaxScaleOnAxis(), 1);

    // A wheel sends a burst; one flick is one page.
    await tester.sendEventToBinding(
      mouse.scroll(
        const Offset(0, 60),
        timeStamp: const Duration(milliseconds: 1100),
      ),
    );
    await tester.pump();
    expect(turns, <bool>[true]);

    await tester.sendEventToBinding(
      mouse.scroll(
        const Offset(0, -60),
        timeStamp: const Duration(milliseconds: 1500),
      ),
    );
    await tester.pump();
    expect(turns, <bool>[true, false]);
  });

  testWidgets('ctrl with the wheel zooms instead', (tester) async {
    final center = await pump(tester);
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(center));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -60)));
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(turns, isEmpty);
    expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
  });
}
