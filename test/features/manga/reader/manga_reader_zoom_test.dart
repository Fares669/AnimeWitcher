import 'package:animewitcher/features/manga/reader/widgets/manga_zoomable_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('double tap toggles page zoom while keeping pinch support', (
    tester,
  ) async {
    final controller = TransformationController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaZoomablePage(
            transformationController: controller,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(controller.value.getMaxScaleOnAxis(), 1);

    await tester.doubleTapAt(
      tester.getCenter(find.byType(MangaZoomablePage)),
    );
    await tester.pumpAndSettle();

    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1));

    await tester.doubleTapAt(
      tester.getCenter(find.byType(MangaZoomablePage)),
    );
    await tester.pumpAndSettle();

    expect(controller.value.getMaxScaleOnAxis(), closeTo(1, 0.001));
  });
}
