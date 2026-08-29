import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/animewitcher_character_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_character_rails.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_extra_tabs.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_poster_grid.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item(String title, String id, {String? relation}) {
  return MultimediaItem(
    title: title,
    url: 'https://example.test/$id',
    posterUrl: '',
    year: 2024,
    catalogType: 'مسلسل',
    relationLabel: relation,
  );
}

Actor _actor({
  required String id,
  required String name,
  required String role,
  int likes = 12,
}) {
  return Actor(id: id, name: name, role: role, likes: likes);
}

Future<ByteData> _fontBytes(String path) async {
  return ByteData.sublistView(await File(path).readAsBytes());
}

Future<void> _loadWalkthroughFonts() async {
  const arabicRegular =
      '/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf';
  if (!File(arabicRegular).existsSync()) return;
  await (FontLoader('NotoSansArabic')
        ..addFont(_fontBytes(arabicRegular))
        ..addFont(
          _fontBytes('/usr/share/fonts/truetype/noto/NotoSansArabic-Bold.ttf'),
        ))
      .load();
  const roboto =
      '/opt/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf';
  if (File(roboto).existsSync()) {
    await (FontLoader('Roboto')..addFont(_fontBytes(roboto))).load();
  }
}

Widget _app(Widget child) {
  return MaterialApp(
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
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: child,
      ),
    ),
  );
}

void main() {
  testWidgets('details extra tabs use APK names and a 3-column similar grid', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    final visited = <int>[];
    await tester.pumpWidget(
      _app(
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            DetailsExtraTabs(
              similar: AsyncData(<MultimediaItem>[
                _item('SimilarOne', 's1'),
                _item('SimilarTwo', 's2'),
                _item('SimilarThree', 's3'),
                _item('SimilarFour', 's4'),
              ]),
              related: const AsyncLoading(),
              relatedHasMore: false,
              cast: const AsyncLoading(),
              onTabBecameVisible: visited.add,
              onAnimeTap: (_) {},
              onCharacterTap: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text(animeWitcherSimilarTabLabel), findsOneWidget);
    expect(find.text(animeWitcherRelatedTabLabel), findsOneWidget);
    expect(find.text(animeWitcherCharactersTabLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('المزيد مثل هذا'), findsNothing);
    expect(find.text('طاقم الشخصيات'), findsNothing);
    expect(visited, contains(0));

    final first = tester.getRect(find.byKey(const ValueKey('similar-0')));
    final second = tester.getRect(find.byKey(const ValueKey('similar-1')));
    final third = tester.getRect(find.byKey(const ValueKey('similar-2')));
    final fourth = tester.getRect(find.byKey(const ValueKey('similar-3')));
    expect((first.top - second.top).abs(), lessThan(1));
    expect((second.top - third.top).abs(), lessThan(1));
    expect(first.left, lessThan(second.left));
    expect(second.left, lessThan(third.left));
    expect(fourth.top, greaterThan(first.bottom - 1));
    expect(find.text('مسلسل'), findsWidgets);
    expect(find.text('2024'), findsWidgets);

    await tester.tap(find.text(animeWitcherRelatedTabLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(visited, contains(1));
    expect(find.text(animeWitcherRelatedEmptyMessage), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    final artifacts = Directory('/opt/cursor/artifacts');
    if (!artifacts.existsSync()) return;
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: const ValueKey('details-extra-tabs-shot'),
          child: ColoredBox(
            color: Colors.black,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                DetailsExtraTabs(
                  similar: AsyncData(<MultimediaItem>[
                    _item('SimilarOne', 's1'),
                    _item('SimilarTwo', 's2'),
                    _item('SimilarThree', 's3'),
                    _item('SimilarFour', 's4'),
                  ]),
                  related: const AsyncLoading(),
                  relatedHasMore: false,
                  cast: const AsyncLoading(),
                  onTabBecameVisible: (_) {},
                  onAnimeTap: (_) {},
                  onCharacterTap: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('details-extra-tabs-shot')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/details_extra_tabs_similar_grid.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });

  testWidgets('related tab wraps 3 posters and appends المزيد', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    var showMore = 0;
    await tester.pumpWidget(
      _app(
        ListView(
          children: [
            DetailsExtraTabs(
              similar: const AsyncData(<MultimediaItem>[]),
              related: AsyncData(<MultimediaItem>[
                _item('RelatedOne', 'r1', relation: 'السابق'),
                _item('RelatedTwo', 'r2', relation: 'التالي'),
                _item('RelatedThree', 'r3', relation: 'قصة جانبية'),
                _item('RelatedFour', 'r4', relation: 'اخري'),
              ]),
              relatedHasMore: true,
              cast: const AsyncLoading(),
              onTabBecameVisible: (_) {},
              onAnimeTap: (_) {},
              onCharacterTap: (_) {},
              onShowMoreRelated: () => showMore++,
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text(animeWitcherRelatedTabLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);

    expect(find.byKey(const ValueKey('related-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('related-more')), findsOneWidget);
    expect(find.text(animeWitcherShowMoreLabel), findsOneWidget);
    expect(find.text('السابق'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('related-more')));
    expect(showMore, 1);
  });

  testWidgets('character tab uses catalog cards on horizontal rails', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    final main = <Actor>[
      for (var index = 0; index < 10; index++)
        _actor(
          id: 'm$index',
          name: 'Main $index',
          role: 'شخصية رئيسية',
          likes: 100 - index,
        ),
    ];
    final supporting = <Actor>[
      _actor(id: 's1', name: 'Support One', role: 'شخصية ثانوية', likes: 9),
      _actor(id: 's2', name: 'Support Two', role: 'شخصية ثانوية', likes: 4),
    ];

    await tester.pumpWidget(
      _app(
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            DetailsCharacterRails(
              cast: <Actor>[...main, ...supporting],
              onCharacterTap: (_) {},
              onShowMore: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.text(animeWitcherMainCharactersHeader), findsOneWidget);
    expect(find.text(animeWitcherSupportingCharactersHeader), findsOneWidget);
    expect(find.text('طاقم الشخصيات'), findsNothing);
    expect(find.byType(CircleAvatar), findsNothing);
    expect(find.byKey(const ValueKey('details-character-rail-Main')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('details-character-rail-Supporting')),
      findsOneWidget,
    );
    expect(
      find.text(animeWitcherShowMoreLabel, skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
      findsNWidgets(2),
    );
    expect(find.byType(GridView), findsNothing);

    final artifacts = Directory('/opt/cursor/artifacts');
    if (!artifacts.existsSync()) return;
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: const ValueKey('details-character-rails-shot'),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              DetailsCharacterRails(
                cast: <Actor>[...main.take(3), ...supporting],
                onCharacterTap: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('details-character-rails-shot')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '${artifacts.path}/details_character_rails.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });

  testWidgets('similar search-disabled message matches the APK', (tester) async {
    await tester.pumpWidget(
      _app(
        DetailsPosterGrid(
          items: const <MultimediaItem>[],
          onItemTap: (_) {},
        ),
      ),
    );
    await tester.pumpWidget(
      _app(
        DetailsExtraTabs(
          similar: AsyncError<List<MultimediaItem>>(
            const AnimeWitcherSearchDisabledException(
              animeWitcherSimilarSearchDisabledMessage,
            ),
            StackTrace.empty,
          ),
          related: const AsyncData(<MultimediaItem>[]),
          relatedHasMore: false,
          cast: const AsyncData(<Actor>[]),
          onTabBecameVisible: (_) {},
          onAnimeTap: (_) {},
          onCharacterTap: (_) {},
        ),
      ),
    );
    await tester.pump();
    expect(find.text(animeWitcherSimilarSearchDisabledMessage), findsOneWidget);
    expect(find.text(animeWitcherSimilarEmptyMessage), findsNothing);
  });
}
