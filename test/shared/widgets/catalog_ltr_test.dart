import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/catalog_ltr.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app({required Widget body}) {
  return MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: body),
  );
}

Widget _threeTileGrid() {
  return GridView.builder(
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 3,
    ),
    itemCount: 3,
    itemBuilder: (context, index) {
      return ColoredBox(
        key: ValueKey('tile-$index'),
        color: Colors.grey,
        child: Center(child: Text('${index + 1}')),
      );
    },
  );
}

void main() {
  testWidgets('Arabic grids start on the right without CatalogLtr', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(body: _threeTileGrid()));

    final first = tester.getTopLeft(find.byKey(const ValueKey('tile-0')));
    final last = tester.getTopLeft(find.byKey(const ValueKey('tile-2')));
    expect(first.dx, greaterThan(last.dx));
  });

  testWidgets('CatalogLtr places the first anime tile on the left', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(body: CatalogLtr(child: _threeTileGrid())));

    final first = tester.getTopLeft(find.byKey(const ValueKey('tile-0')));
    final middle = tester.getTopLeft(find.byKey(const ValueKey('tile-1')));
    final last = tester.getTopLeft(find.byKey(const ValueKey('tile-2')));
    expect(first.dx, lessThan(middle.dx));
    expect(middle.dx, lessThan(last.dx));
  });
}
