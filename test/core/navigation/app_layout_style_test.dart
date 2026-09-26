import 'package:animewitcher/core/navigation/app_layout_style.dart';
import 'package:animewitcher/shared/widgets/app_layout_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a stored name reads back, anything else reads as no choice', () {
    for (final style in AppLayoutStyle.values) {
      expect(AppLayoutStyle.fromName(style.name), style);
    }
    expect(AppLayoutStyle.fromName(null), isNull);
    expect(AppLayoutStyle.fromName('sidebar'), isNull);
  });

  test('phones always get the bottom bar', () {
    expect(appLayoutChoices(wide: false), [AppLayoutStyle.dock]);
    for (final stored in <AppLayoutStyle?>[null, ...AppLayoutStyle.values]) {
      expect(
        effectiveAppLayout(stored: stored, isDesktopPlatform: false),
        AppLayoutStyle.dock,
      );
    }
  });

  test('a desktop draws its choice, and the bottom bar before one', () {
    expect(appLayoutChoices(wide: true), [
      AppLayoutStyle.dock,
      AppLayoutStyle.sideRail,
      AppLayoutStyle.topBar,
    ]);
    expect(
      effectiveAppLayout(stored: null, isDesktopPlatform: true),
      AppLayoutStyle.dock,
    );
    for (final style in appLayoutChoices(wide: true)) {
      expect(effectiveAppLayout(stored: style, isDesktopPlatform: true), style);
    }
  });

  test('only a desktop with no choice yet is asked', () {
    expect(
      shouldAskForAppLayout(stored: null, isDesktopPlatform: true),
      isTrue,
    );
    expect(
      shouldAskForAppLayout(stored: null, isDesktopPlatform: false),
      isFalse,
    );
    for (final style in AppLayoutStyle.values) {
      expect(
        shouldAskForAppLayout(stored: style, isDesktopPlatform: true),
        isFalse,
      );
    }
  });

  testWidgets('every layout preview draws without overflowing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              for (final style in AppLayoutStyle.values)
                SizedBox(
                  width: 180,
                  child: AppLayoutOptionCard(
                    style: style,
                    arabic: true,
                    selected: style == AppLayoutStyle.dock,
                    onTap: () {},
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('شريط جانبي'), findsOneWidget);
    expect(find.text('شريط علوي'), findsOneWidget);
    expect(find.text('الشريط السفلي'), findsOneWidget);
  });

  testWidgets('the phone cards draw upright without overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final style in appLayoutChoices(wide: false))
                SizedBox(
                  width: 160,
                  child: AppLayoutOptionCard(
                    style: style,
                    arabic: true,
                    selected: style == AppLayoutStyle.dock,
                    phone: true,
                    onTap: () {},
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final preview = tester.getSize(find.byType(AppLayoutPreview).first);
    expect(preview.height, greaterThan(preview.width));
  });

  testWidgets('tablets get the layouts, phones keep the dock', (tester) async {
    Future<bool> availableAt(Size size) async {
      late bool available;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: Builder(
            builder: (context) {
              available = appLayoutsAvailable(context);
              return const SizedBox();
            },
          ),
        ),
      );
      return available;
    }

    // Tests run as Android: the size decides.
    expect(await availableAt(const Size(390, 844)), isFalse); // phone
    expect(await availableAt(const Size(844, 390)), isFalse); // on its side
    expect(await availableAt(const Size(820, 1180)), isTrue); // tablet
    expect(await availableAt(const Size(1180, 820)), isTrue); // on its side
  });
}
