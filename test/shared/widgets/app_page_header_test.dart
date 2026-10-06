import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
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

  testWidgets('matches the title typography of the old standard AppBar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const title = 'Favorites';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: const Text(
              title,
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final standard = tester
        .renderObject<RenderParagraph>(find.text(title))
        .text
        .style!;

    await tester.pumpWidget(
      app(locale: const Locale('en'), title: title),
    );
    await tester.pumpAndSettle();
    final progressive = tester
        .renderObject<RenderParagraph>(find.text(title))
        .text
        .style!;

    expect(progressive.fontSize, standard.fontSize);
    expect(progressive.fontFamily, standard.fontFamily);
    expect(progressive.fontWeight, standard.fontWeight);
    expect(progressive.color, standard.color);
  });

  testWidgets('accepts progressive blur calibration without stacking filters', (
    tester,
  ) async {
    Object? widget;
    try {
      widget = Function.apply(
        AppProgressiveHeaderBackdrop.new,
        const <Object?>[],
        const <Symbol, Object?>{
          #maxSigma: 12.0,
          #falloff: 1.2,
        },
      );
    } catch (_) {
      widget = null;
    }

    expect(widget, isA<AppProgressiveHeaderBackdrop>());

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 100,
            child: widget! as Widget,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BackdropFilter), findsAtMostNWidgets(1));
  });

  testWidgets('uses one fixed blur with a soft visual fade at the edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      app(
        locale: const Locale('en'),
        title: 'Settings',
      ),
    );
    await tester.pumpAndSettle();

    final backdrop = find.byType(AppProgressiveHeaderBackdrop);
    expect(backdrop, findsOneWidget);

    expect(
      find.descendant(
        of: backdrop,
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );

    final gradients = find.descendant(
      of: backdrop,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).gradient is LinearGradient,
      ),
    );
    expect(gradients, findsOneWidget);

    final box = tester.widget<DecoratedBox>(gradients);
    final gradient = (box.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors.last.a, 0);
  });
}
