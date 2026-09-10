import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/characters/presentation/character_animes_grid.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';

MultimediaItem _show({
  required String title,
  required String id,
  required String role,
  int year = 2013,
  String type = 'مسلسل',
}) {
  return MultimediaItem(
    title: title,
    url: 'https://animewitcher.com/watch/$id',
    posterUrl: '',
    year: year,
    catalogType: type,
    relationLabel: role,
  );
}

Future<void> _loadWalkthroughFonts() => TestFonts.loadWalkthroughFonts();

void main() {
  testWidgets('character animes wrap in a 3-column RTL grid', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    final items = <MultimediaItem>[
      _show(title: 'One Piece', id: 'op1', role: 'شخصية رئيسية', year: 1999),
      _show(
        title: 'One Piece Film Z',
        id: 'opz',
        role: 'شخصية رئيسية',
        year: 2012,
        type: 'فيلم',
      ),
      _show(
        title: 'One Piece Film Gold',
        id: 'opg',
        role: 'شخصية رئيسية',
        year: 2016,
        type: 'فيلم',
      ),
      _show(
        title: 'One Piece Stampede',
        id: 'ops',
        role: 'شخصية رئيسية',
        year: 2019,
        type: 'فيلم',
      ),
      _show(
        title: 'One Piece Red',
        id: 'opr',
        role: 'شخصية رئيسية',
        year: 2022,
        type: 'فيلم',
      ),
      _show(
        title: 'Chopper Special',
        id: 'opc',
        role: 'شخصية ثانوية',
        year: 2008,
        type: 'خاصة',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'NotoSansArabic',
          scaffoldBackgroundColor: Colors.black,
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFEEC60A),
            surface: Color(0xFF000000),
            onSurface: Color(0xFFE5E7EB),
          ),
        ),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: RepaintBoundary(
            key: const ValueKey('character-animes-grid-shot'),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  CharacterAnimesGrid(
                    title: 'الأنميات',
                    items: items,
                    onItemTap: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('الأنميات'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.scrollDirection == Axis.horizontal,
      ),
      findsNothing,
    );

    final first = tester.getRect(
      find.byKey(const ValueKey('character-animes-grid-0')),
    );
    final second = tester.getRect(
      find.byKey(const ValueKey('character-animes-grid-1')),
    );
    final third = tester.getRect(
      find.byKey(const ValueKey('character-animes-grid-2')),
    );
    final fourth = tester.getRect(
      find.byKey(const ValueKey('character-animes-grid-3')),
    );

    expect((first.top - second.top).abs(), lessThan(1));
    expect((second.top - third.top).abs(), lessThan(1));
    expect(
      first.left,
      greaterThan(second.left),
      reason: 'first poster sits on the right in RTL',
    );
    expect(second.left, greaterThan(third.left));
    expect(fourth.top, greaterThan(first.bottom - 1));

    expect(find.text('شخصية رئيسية'), findsWidgets);
    expect(find.text('شخصية ثانوية'), findsOneWidget);
    expect(find.text('مسلسل'), findsWidgets);
    expect(find.text('فيلم'), findsWidgets);
    expect(find.text('1999'), findsOneWidget);

    final artifacts = debugShotDirectory();
    if (artifacts == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('character-animes-grid-shot')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/character_animes_rtl_grid.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });

  testWidgets('two character animes start on the right under the title', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: 'NotoSansArabic',
          scaffoldBackgroundColor: Colors.black,
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFEEC60A),
            surface: Color(0xFF000000),
            onSurface: Color(0xFFE5E7EB),
          ),
        ),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: RepaintBoundary(
            key: const ValueKey('character-animes-two-shot'),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  CharacterAnimesGrid(
                    title: 'الأنميات',
                    items: [
                      _show(
                        title: 'Death Note',
                        id: 'dn2006',
                        role: 'شخصية رئيسية',
                        year: 2006,
                      ),
                      _show(
                        title: 'Death Note: Rewrite',
                        id: 'dn2007',
                        role: 'شخصية رئيسية',
                        year: 2007,
                      ),
                    ],
                    onItemTap: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final titleBox = tester.getRect(find.text('الأنميات'));
    final first = tester.getRect(find.byKey(const ValueKey('character-animes-grid-0')));
    final second = tester.getRect(find.byKey(const ValueKey('character-animes-grid-1')));

    expect(first.left, greaterThan(second.left));
    expect(first.right, greaterThan(390 / 2));
    expect((titleBox.right - first.right).abs(), lessThan(24));

    final artifacts = debugShotDirectory();
    if (artifacts == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('character-animes-two-shot')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/character_animes_two_cards_rtl.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
