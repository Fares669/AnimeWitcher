import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/animewitcher_character_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_character_rails.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_extra_tabs.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_poster_grid.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/paged_rail.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/test_fonts.dart';

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

Future<void> _loadWalkthroughFonts() => TestFonts.loadWalkthroughFonts();

Future<void> _settleCharacterRails(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

ScrollableState _railScrollable(WidgetTester tester, String role) {
  return tester.state<ScrollableState>(
    find.descendant(
      of: find.byKey(ValueKey('details-character-rail-$role')),
      matching: find.byType(Scrollable),
    ),
  );
}

Future<void> _writeShot(WidgetTester tester, String filename, Key key) async {
  final artifacts = Directory('/opt/cursor/artifacts');
  if (!artifacts.existsSync()) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(
      '${artifacts.path}/$filename',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

List<Actor> _mainActors(int count) {
  return <Actor>[
    for (var index = 0; index < count; index++)
      _actor(
        id: 'm$index',
        name: 'Main $index',
        role: 'شخصية رئيسية',
        likes: 100 - index,
      ),
  ];
}

Widget _app(Widget child) {
  return ProviderScope(
    child: MaterialApp(
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
        body: Directionality(textDirection: TextDirection.rtl, child: child),
      ),
    ),
  );
}

void main() {
  test(
    'cast strip shows المزيد only when more than 10 characters are fetched',
    () {
      expect(animeWitcherCastStripShowsMore(10), isFalse);
      expect(animeWitcherCastStripShowsMore(11), isTrue);
      expect(animeWitcherCastStripVisibleCount(10), 10);
      expect(animeWitcherCastStripVisibleCount(11), 10);
      expect(animeWitcherCastStripVisibleCount(3), 3);
    },
  );

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
    expect(visited, contains(detailsExtraSimilarTabIndex));

    final tabBar = tester.getRect(find.byType(TabBar));
    expect(tabBar.left, closeTo(0, 0.5));
    expect(tabBar.width, closeTo(390, 0.5));
    final tabRects = tester.widgetList<Tab>(find.byType(Tab)).map((tab) {
      return tester.getRect(find.byWidget(tab));
    }).toList();
    expect(tabRects, hasLength(3));
    expect((tabRects[0].width - tabRects[1].width).abs(), lessThan(1));
    expect((tabRects[1].width - tabRects[2].width).abs(), lessThan(1));
    expect(tabRects[0].width, closeTo(390 / 3, 1));
    expect(tabRects[0].center.dx, greaterThan(tabRects[1].center.dx));
    expect(tabRects[1].center.dx, greaterThan(tabRects[2].center.dx));
    expect(
      tester.getCenter(find.text(animeWitcherCharactersTabLabel)).dx,
      greaterThan(tester.getCenter(find.text(animeWitcherRelatedTabLabel)).dx),
    );
    expect(
      tester.getCenter(find.text(animeWitcherRelatedTabLabel)).dx,
      greaterThan(tester.getCenter(find.text(animeWitcherSimilarTabLabel)).dx),
    );

    final first = tester.getRect(find.byKey(const ValueKey('similar-0')));
    final second = tester.getRect(find.byKey(const ValueKey('similar-1')));
    final third = tester.getRect(find.byKey(const ValueKey('similar-2')));
    final fourth = tester.getRect(find.byKey(const ValueKey('similar-3')));
    expect((first.top - second.top).abs(), lessThan(1));
    expect((second.top - third.top).abs(), lessThan(1));
    expect(first.left, greaterThan(second.left));
    expect(second.left, greaterThan(third.left));
    expect(fourth.top, greaterThan(first.bottom - 1));
    expect(find.text('مسلسل'), findsWidgets);
    expect(find.text('2024'), findsWidgets);

    await tester.tap(find.text(animeWitcherRelatedTabLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(visited, contains(detailsExtraRelatedTabIndex));
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

  testWidgets('related tab wraps 3 posters and appends المزيد after five', (
    tester,
  ) async {
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
                for (var index = 1; index <= 7; index++)
                  _item(
                    'Related$index',
                    'r$index',
                    relation: index == 1 ? 'السابق' : 'اخري',
                  ),
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
    expect(find.byKey(const ValueKey('related-4')), findsOneWidget);
    expect(find.byKey(const ValueKey('related-5')), findsNothing);
    expect(find.byKey(const ValueKey('related-more')), findsOneWidget);
    expect(find.text(animeWitcherShowMoreLabel), findsOneWidget);
    expect(find.text('السابق'), findsOneWidget);

    final first = tester.getRect(find.byKey(const ValueKey('related-0')));
    final second = tester.getRect(find.byKey(const ValueKey('related-1')));
    final third = tester.getRect(find.byKey(const ValueKey('related-2')));
    expect((first.top - second.top).abs(), lessThan(1));
    expect(first.left, greaterThan(second.left));
    expect(second.left, greaterThan(third.left));

    await tester.tap(find.byKey(const ValueKey('related-more')));
    expect(showMore, 1);
  });

  testWidgets('character tab uses catalog cards on horizontal rails', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    final main = _mainActors(11);
    final supporting = <Actor>[
      _actor(id: 's1', name: 'Support One', role: 'شخصية ثانوية', likes: 9),
      _actor(id: 's2', name: 'Support Two', role: 'شخصية ثانوية', likes: 4),
    ];
    final openedRoles = <String>[];

    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: const ValueKey('details-character-rails-shot'),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              DetailsCharacterRails(
                cast: <Actor>[...main, ...supporting],
                onCharacterTap: (_) {},
                onShowMore: openedRoles.add,
              ),
            ],
          ),
        ),
      ),
    );
    await _settleCharacterRails(tester);

    expect(find.text(animeWitcherMainCharactersHeader), findsOneWidget);
    expect(find.text(animeWitcherSupportingCharactersHeader), findsOneWidget);
    expect(find.text('طاقم الشخصيات'), findsNothing);
    expect(find.byType(CircleAvatar), findsNothing);
    expect(
      find.byKey(const ValueKey('details-character-rail-Main')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('details-character-rail-Supporting')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ListView && widget.scrollDirection == Axis.horizontal,
      ),
      findsNWidgets(2),
    );
    expect(find.byType(GridView), findsNothing);
    expect(
      find.byKey(const ValueKey('details-character-Main-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('details-character-Main-10')),
      findsNothing,
    );

    final mainScrollable = _railScrollable(tester, 'Main');
    expect(
      mainScrollable.position.pixels,
      mainScrollable.position.minScrollExtent,
    );
    expect(
      _railScrollable(tester, 'Supporting').position.pixels,
      _railScrollable(tester, 'Supporting').position.minScrollExtent,
    );

    final rail = tester.getRect(
      find.byKey(const ValueKey('details-character-rail-Main')),
    );
    final mainFirst = tester.getRect(
      find.byKey(const ValueKey('details-character-Main-0')),
    );
    final mainSecond = tester.getRect(
      find.byKey(const ValueKey('details-character-Main-1')),
    );
    expect(mainFirst.left, greaterThan(mainSecond.left));
    expect(mainFirst.right, closeTo(rail.right, 1.5));
    expect(
      find.byKey(const ValueKey('details-character-Main-more')),
      findsNothing,
    );

    final directionality = tester.widget<Directionality>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('details-character-rail-Main')),
            matching: find.byType(Directionality),
          )
          .first,
    );
    expect(directionality.textDirection, TextDirection.rtl);
    expect(
      tester
          .widget<PagedRail>(
            find.byKey(const ValueKey('details-character-rail-Main')),
          )
          .reverse,
      isFalse,
    );

    await _writeShot(
      tester,
      'details_character_rails_rtl_start.png',
      const ValueKey('details-character-rails-shot'),
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('details-character-Main-more')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('details-character-rail-Main')),
        matching: find.byType(Scrollable),
      ),
    );
    final moreScrollable = _railScrollable(tester, 'Main');
    moreScrollable.position.jumpTo(moreScrollable.position.maxScrollExtent);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('details-character-Main-more')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('details-character-Main-9')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('details-character-Main-10')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('details-character-Supporting-more')),
      findsNothing,
    );

    await _writeShot(
      tester,
      'details_character_rails_more_left_end.png',
      const ValueKey('details-character-rails-shot'),
    );

    await tester.tap(find.byKey(const ValueKey('details-character-Main-more')));
    expect(openedRoles, <String>['Main']);
  });

  testWidgets('exactly 10 main characters skip المزيد', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: const ValueKey('details-character-ten-shot'),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              DetailsCharacterRails(
                cast: _mainActors(10),
                onCharacterTap: (_) {},
                onShowMore: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await _settleCharacterRails(tester);

    expect(
      find.byKey(const ValueKey('details-character-Main-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('details-character-Main-10')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('details-character-Main-more')),
      findsNothing,
    );

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('details-character-Main-9')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('details-character-rail-Main')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      find.byKey(const ValueKey('details-character-Main-9')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('details-character-Main-more')),
      findsNothing,
    );
    expect(find.text(animeWitcherShowMoreLabel), findsNothing);

    await _writeShot(
      tester,
      'details_character_rails_ten_no_more.png',
      const ValueKey('details-character-ten-shot'),
    );
  });

  testWidgets('opening the characters extra tab keeps rails at the RTL start', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        ListView(
          children: [
            DetailsExtraTabs(
              similar: AsyncData(<MultimediaItem>[_item('SimilarOne', 's1')]),
              related: const AsyncData(<MultimediaItem>[]),
              relatedHasMore: false,
              cast: AsyncData(_mainActors(11)),
              onTabBecameVisible: (_) {},
              onAnimeTap: (_) {},
              onCharacterTap: (_) {},
              onShowMoreCharacters: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('similar-0')), findsOneWidget);

    await tester.tap(find.text(animeWitcherCharactersTabLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await _settleCharacterRails(tester);

    final mainScrollable = _railScrollable(tester, 'Main');
    expect(
      mainScrollable.position.pixels,
      mainScrollable.position.minScrollExtent,
    );
    final rail = tester.getRect(
      find.byKey(const ValueKey('details-character-rail-Main')),
    );
    final mainFirst = tester.getRect(
      find.byKey(const ValueKey('details-character-Main-0')),
    );
    expect(mainFirst.right, closeTo(rail.right, 2));
    expect(
      find.byKey(const ValueKey('details-character-Main-more')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('details-character-Main-10')),
      findsNothing,
    );
  });

  testWidgets('similar search-disabled message matches the APK', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        DetailsPosterGrid(items: const <MultimediaItem>[], onItemTap: (_) {}),
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

  testWidgets(
    'empty and loading extra tabs keep the 6-card height and center',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 920));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(_loadWalkthroughFonts);

      Future<Size> pumpBody({
        required AsyncValue<List<MultimediaItem>> similar,
        required AsyncValue<List<MultimediaItem>> related,
      }) async {
        await tester.pumpWidget(
          _app(
            DetailsExtraTabs(
              similar: similar,
              related: related,
              relatedHasMore: false,
              cast: const AsyncLoading(),
              onTabBecameVisible: (_) {},
              onAnimeTap: (_) {},
              onCharacterTap: (_) {},
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        return tester.getSize(
          find.byKey(const ValueKey('details-extra-tab-view')),
        );
      }

      final loadingSize = await pumpBody(
        similar: const AsyncLoading(),
        related: const AsyncLoading(),
      );
      final emptySize = await pumpBody(
        similar: const AsyncData(<MultimediaItem>[]),
        related: const AsyncData(<MultimediaItem>[]),
      );
      final filledSize = await pumpBody(
        similar: AsyncData(<MultimediaItem>[
          for (var index = 0; index < 6; index++) _item('S$index', 's$index'),
        ]),
        related: const AsyncData(<MultimediaItem>[]),
      );

      expect(loadingSize.height, closeTo(emptySize.height, 0.5));
      expect(emptySize.height, closeTo(filledSize.height, 0.5));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text(animeWitcherRelatedTabLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text(animeWitcherRelatedEmptyMessage), findsOneWidget);
      final box = tester.getRect(
        find.byKey(const ValueKey('details-extra-tab-view')),
      );
      final message = tester.getCenter(
        find.text(animeWitcherRelatedEmptyMessage),
      );
      expect((message.dx - box.center.dx).abs(), lessThan(24));
      expect((message.dy - box.center.dy).abs(), lessThan(48));

      final artifacts = Directory('/opt/cursor/artifacts');
      if (!artifacts.existsSync()) return;
      await tester.pumpWidget(
        _app(
          RepaintBoundary(
            key: const ValueKey('details-extra-empty-shot'),
            child: ColoredBox(
              color: Colors.black,
              child: DetailsExtraTabs(
                similar: const AsyncData(<MultimediaItem>[]),
                related: const AsyncData(<MultimediaItem>[]),
                relatedHasMore: false,
                cast: const AsyncData(<Actor>[]),
                onTabBecameVisible: (_) {},
                onAnimeTap: (_) {},
                onCharacterTap: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text(animeWitcherRelatedTabLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('details-extra-empty-shot')),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '${artifacts.path}/details_extra_tabs_related_empty.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
    },
  );

  testWidgets(
    'similar tab shows five posters plus المزيد when count exceeds 6',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 920));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var openedSimilar = 0;
      await tester.pumpWidget(
        _app(
          ListView(
            children: [
              DetailsExtraTabs(
                similar: AsyncData(<MultimediaItem>[
                  for (var index = 0; index < 7; index++)
                    _item('Similar$index', 's$index'),
                ]),
                similarHasMore: true,
                related: const AsyncData(<MultimediaItem>[]),
                relatedHasMore: false,
                cast: const AsyncLoading(),
                onTabBecameVisible: (_) {},
                onAnimeTap: (_) {},
                onCharacterTap: (_) {},
                onShowMoreSimilar: () => openedSimilar++,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('similar-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('similar-4')), findsOneWidget);
      expect(find.byKey(const ValueKey('similar-5')), findsNothing);
      expect(find.byKey(const ValueKey('similar-more')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('similar-more')));
      expect(openedSimilar, 1);
    },
  );

  testWidgets('six similar titles show all posters and skip المزيد', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        ListView(
          children: [
            DetailsExtraTabs(
              similar: AsyncData(<MultimediaItem>[
                for (var index = 0; index < 6; index++)
                  _item('Similar$index', 's$index'),
              ]),
              related: const AsyncData(<MultimediaItem>[]),
              relatedHasMore: false,
              cast: const AsyncLoading(),
              onTabBecameVisible: (_) {},
              onAnimeTap: (_) {},
              onCharacterTap: (_) {},
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('similar-5')), findsOneWidget);
    expect(find.byKey(const ValueKey('similar-more')), findsNothing);
  });

  testWidgets('similar المزيد opens the full similar page', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            return ListView(
              children: [
                DetailsExtraTabs(
                  similar: AsyncData(<MultimediaItem>[
                    for (var index = 0; index < 8; index++)
                      _item('Similar$index', 's$index'),
                  ]),
                  similarHasMore: true,
                  related: const AsyncData(<MultimediaItem>[]),
                  relatedHasMore: false,
                  cast: const AsyncLoading(),
                  onTabBecameVisible: (_) {},
                  onAnimeTap: (_) {},
                  onCharacterTap: (_) {},
                  onShowMoreSimilar: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          appBar: AppBar(
                            title: const Text(animeWitcherSimilarTabLabel),
                          ),
                          body: const Center(child: Text('similar-full-page')),
                        ),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('similar-more')));
    await tester.pumpAndSettle();
    expect(find.text('similar-full-page'), findsOneWidget);
    expect(find.text(animeWitcherSimilarTabLabel), findsWidgets);
  });

  testWidgets('related المزيد opens the full related page', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            return ListView(
              children: [
                DetailsExtraTabs(
                  similar: const AsyncData(<MultimediaItem>[]),
                  related: AsyncData(<MultimediaItem>[
                    for (var index = 0; index < 8; index++)
                      _item('Related$index', 'r$index'),
                  ]),
                  relatedHasMore: true,
                  cast: const AsyncLoading(),
                  onTabBecameVisible: (_) {},
                  onAnimeTap: (_) {},
                  onCharacterTap: (_) {},
                  onShowMoreRelated: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          appBar: AppBar(
                            title: const Text(animeWitcherRelatedTabLabel),
                          ),
                          body: const Center(child: Text('related-full-page')),
                        ),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text(animeWitcherRelatedTabLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const ValueKey('related-more')));
    await tester.pumpAndSettle();
    expect(find.text('related-full-page'), findsOneWidget);
    expect(find.text(animeWitcherRelatedTabLabel), findsWidgets);
  });

  testWidgets('extra-tab swipe does not switch details and episodes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final parentController = TabController(length: 2, vsync: tester);
    addTearDown(parentController.dispose);

    await tester.pumpWidget(
      _app(
        Column(
          children: [
            Expanded(
              child: TabBarView(
                key: const ValueKey('parent-details-pager'),
                controller: parentController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  ListView(
                    children: [
                      const SizedBox(
                        height: 160,
                        child: Center(child: Text('above-extra')),
                      ),
                      DetailsExtraTabs(
                        similar: AsyncData(<MultimediaItem>[
                          _item('SimilarOne', 's1'),
                        ]),
                        related: const AsyncData(<MultimediaItem>[]),
                        relatedHasMore: false,
                        cast: const AsyncData(<Actor>[]),
                        onTabBecameVisible: (_) {},
                        onAnimeTap: (_) {},
                        onCharacterTap: (_) {},
                      ),
                    ],
                  ),
                  const Center(child: Text('episodes-page')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(parentController.index, 0);
    expect(find.text('above-extra'), findsOneWidget);

    final extraRect = tester.getRect(
      find.byKey(const ValueKey('details-extra-tab-view')),
    );
    await tester.timedDragFrom(
      extraRect.center,
      const Offset(-280, 0),
      const Duration(milliseconds: 280),
    );
    await tester.pumpAndSettle();
    if (find.text(animeWitcherRelatedEmptyMessage).evaluate().isEmpty &&
        find.text(animeWitcherCharactersEmptyMessage).evaluate().isEmpty) {
      await tester.timedDragFrom(
        extraRect.center,
        const Offset(280, 0),
        const Duration(milliseconds: 280),
      );
      await tester.pumpAndSettle();
    }
    expect(parentController.index, 0);
    expect(find.text('episodes-page'), findsNothing);
    expect(
      find.text(animeWitcherRelatedEmptyMessage).evaluate().isNotEmpty ||
          find.text(animeWitcherCharactersEmptyMessage).evaluate().isNotEmpty,
      isTrue,
    );
  });

  testWidgets(
    'characters tab has no nested vertical scroll and both rails stay in view',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 920));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(_loadWalkthroughFonts);

      await tester.pumpWidget(
        _app(
          ListView(
            children: [
              DetailsExtraTabs(
                similar: AsyncData(<MultimediaItem>[_item('SimilarOne', 's1')]),
                related: const AsyncData(<MultimediaItem>[]),
                relatedHasMore: false,
                cast: AsyncData(<Actor>[
                  ..._mainActors(11),
                  _actor(
                    id: 's1',
                    name: 'Support One',
                    role: 'شخصية ثانوية',
                    likes: 9,
                  ),
                  _actor(
                    id: 's2',
                    name: 'Support Two',
                    role: 'شخصية ثانوية',
                    likes: 4,
                  ),
                ]),
                onTabBecameVisible: (_) {},
                onAnimeTap: (_) {},
                onCharacterTap: (_) {},
                onShowMoreCharacters: (_) {},
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text(animeWitcherCharactersTabLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await _settleCharacterRails(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('details-extra-tab-view')),
          matching: find.byWidgetPredicate((widget) {
            return widget is Scrollable &&
                (widget.axisDirection == AxisDirection.down ||
                    widget.axisDirection == AxisDirection.up);
          }),
        ),
        findsNothing,
      );

      final tabView = tester.getRect(
        find.byKey(const ValueKey('details-extra-tab-view')),
      );
      final mainHeader = tester.getRect(
        find.text(animeWitcherMainCharactersHeader),
      );
      final supportHeader = tester.getRect(
        find.text(animeWitcherSupportingCharactersHeader),
      );
      final supportRail = tester.getRect(
        find.byKey(const ValueKey('details-character-rail-Supporting')),
      );
      expect(mainHeader.top, greaterThanOrEqualTo(tabView.top - 0.5));
      expect(supportHeader.top, greaterThan(mainHeader.bottom));
      expect(supportRail.bottom, lessThanOrEqualTo(tabView.bottom + 1));
    },
  );

  testWidgets('vertical drag on characters scrolls the parent details page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 920));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(_loadWalkthroughFonts);

    await tester.pumpWidget(
      _app(
        ListView(
          children: [
            const SizedBox(
              height: 360,
              child: Center(child: Text('above-extra')),
            ),
            DetailsExtraTabs(
              similar: AsyncData(<MultimediaItem>[_item('SimilarOne', 's1')]),
              related: const AsyncData(<MultimediaItem>[]),
              relatedHasMore: false,
              cast: AsyncData(_mainActors(11)),
              onTabBecameVisible: (_) {},
              onAnimeTap: (_) {},
              onCharacterTap: (_) {},
              onShowMoreCharacters: (_) {},
            ),
            const SizedBox(
              height: 1400,
              child: Center(child: Text('below-extra')),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text(animeWitcherCharactersTabLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await _settleCharacterRails(tester);

    final parent = tester.state<ScrollableState>(
      find.byWidgetPredicate((widget) {
        return widget is Scrollable &&
            widget.axisDirection == AxisDirection.down;
      }).first,
    );
    expect(parent.position.pixels, 0);

    await tester.timedDrag(
      find.text(animeWitcherMainCharactersHeader),
      const Offset(0, -220),
      const Duration(milliseconds: 280),
    );
    await tester.pumpAndSettle();

      expect(parent.position.pixels, greaterThan(80));
  });
}
