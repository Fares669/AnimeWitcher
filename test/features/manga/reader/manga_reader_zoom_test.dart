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

    final center = tester.getCenter(find.byType(MangaZoomablePage));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await tester.pumpAndSettle();

    expect(controller.value.getMaxScaleOnAxis(), greaterThan(1));

    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await tester.pumpAndSettle();

    expect(controller.value.getMaxScaleOnAxis(), closeTo(1, 0.001));
  });


  testWidgets('navigate-to-pan consumes navigation before changing page', (
    tester,
  ) async {
    final transform = TransformationController();
    final navigation = MangaZoomNavigationController();
    addTearDown(transform.dispose);
    addTearDown(navigation.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaZoomablePage(
            transformationController: transform,
            navigationController: navigation,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(navigation.tryPan(forward: true, rtl: false), isFalse);

    final center = tester.getCenter(find.byType(MangaZoomablePage));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await tester.pumpAndSettle();

    final before = transform.value.getTranslation().x;
    expect(transform.value.getMaxScaleOnAxis(), greaterThan(1));
    expect(navigation.tryPan(forward: true, rtl: false), isTrue);
    await tester.pump();
    expect(transform.value.getTranslation().x, lessThan(before));
  });
}
