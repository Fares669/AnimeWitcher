import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/widgets/library_media_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('library media selector switches between anime and manga', (
    tester,
  ) async {
    LibraryMediaKind? selected;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const <Locale>[Locale('ar'), Locale('en')],
        home: Scaffold(
          appBar: AppBar(
            title: LibraryMediaSelector(
              selected: LibraryMediaKind.anime,
              onSelected: (value) => selected = value,
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.textContaining('أنمي'), findsWidgets);

    await tester.tap(find.byTooltip('نوع المكتبة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مانجا'));
    await tester.pumpAndSettle();

    expect(selected, LibraryMediaKind.manga);
  });
}
