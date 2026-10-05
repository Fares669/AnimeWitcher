import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app({
    required Locale locale,
    required String title,
    List<Widget> actions = const <Widget>[],
  }) {
    return MaterialApp(
      locale: locale,
      supportedLocales: const <Locale>[Locale('en'), Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        appBar: AppPageAppBar(title: title, actions: actions),
        body: const SizedBox.expand(),
      ),
    );
  }

  Future<void> expectTitlePhysicallyCentered(
    WidgetTester tester,
    Locale locale,
    String title, {
    List<Widget> actions = const <Widget>[],
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      app(locale: locale, title: title, actions: actions),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getCenter(find.text(title)).dx,
      closeTo(200, 1),
    );
  }

  testWidgets('centers the page title on the physical screen in English', (
    tester,
  ) async {
    await expectTitlePhysicallyCentered(
      tester,
      const Locale('en'),
      'Coming soon',
    );
  });

  testWidgets('centers the page title on the physical screen in Arabic', (
    tester,
  ) async {
    await expectTitlePhysicallyCentered(
      tester,
      const Locale('ar'),
      'القادم قريبًا',
    );
  });

  testWidgets('back stays on the physical left in Arabic', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      app(
        locale: const Locale('ar'),
        title: 'المواسم',
      ),
    );
    await tester.pumpAndSettle();

    final backCenter = tester.getCenter(find.byType(AppBackButton));
    expect(backCenter.dx, lessThan(80));
  });

  testWidgets('trailing actions do not move the title off center', (
    tester,
  ) async {
    await expectTitlePhysicallyCentered(
      tester,
      const Locale('ar'),
      'الردود',
      actions: const <Widget>[
        SizedBox(
          key: ValueKey<String>('header-action'),
          width: 56,
          child: Icon(Icons.sort_rounded),
        ),
      ],
    );
  });

  testWidgets('long title stays on one line clear of header controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const title =
        'A very long page title that must not cover navigation controls';
    await tester.pumpWidget(
      app(
        locale: const Locale('en'),
        title: title,
        actions: const <Widget>[
          SizedBox(
            key: ValueKey<String>('header-action'),
            width: 56,
            child: Icon(Icons.sort_rounded),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final titleWidget = tester.widget<Text>(find.text(title));
    expect(titleWidget.maxLines, 1);
    expect(titleWidget.overflow, TextOverflow.ellipsis);

    final titleRect = tester.getRect(find.text(title));
    final backRect = tester.getRect(find.byType(AppBackButton));
    final actionRect = tester.getRect(
      find.byKey(const ValueKey<String>('header-action')),
    );
    expect(titleRect.left, greaterThanOrEqualTo(backRect.right));
    expect(titleRect.right, lessThanOrEqualTo(actionRect.left));
  });

  testWidgets('contains multiple blur bands for progressive backdrop', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        locale: const Locale('en'),
        title: 'Settings',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppProgressiveHeaderBackdrop), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppProgressiveHeaderBackdrop),
        matching: find.byType(BackdropFilter),
      ),
      findsAtLeastNWidgets(3),
    );
  });
}
