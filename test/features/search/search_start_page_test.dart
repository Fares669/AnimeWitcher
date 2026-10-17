import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_start_page.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

SearchStartPage _page({
  List<String> recents = const <String>[],
  ValueChanged<String>? onRecent,
}) => SearchStartPage(
  recents: recents,
  onRecent: onRecent ?? (_) {},
  onRemoveRecent: (_) {},
  onClearRecents: () {},
);

void main() {
  testWidgets('a recent search runs again when tapped', (tester) async {
    String? ran;
    await tester.pumpWidget(
      _app(_page(recents: const ['One Piece'], onRecent: (q) => ran = q)),
    );
    await tester.tap(find.text('One Piece'));
    expect(ran, 'One Piece');
  });

  testWidgets('recent-search clear matches the home clear-all treatment', (
    tester,
  ) async {
    var cleared = 0;
    await tester.pumpWidget(
      _app(
        SearchStartPage(
          recents: const <String>['One Piece'],
          onRecent: (_) {},
          onRemoveRecent: (_) {},
          onClearRecents: () => cleared++,
        ),
      ),
    );

    expect(find.text('مسح الكل'), findsOneWidget);
    final deleteIcon = find.byIcon(Icons.delete_outline);
    expect(deleteIcon, findsOneWidget);
    expect(tester.widget<Icon>(deleteIcon).color, Colors.red);
    await tester.tap(find.text('مسح الكل'));
    expect(cleared, 1);
  });

  testWidgets('recent searches stay on one horizontally scrollable RTL row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const recents = <String>[
      'Mao',
      'One Piece',
      'Buchigire Reijou wa Houfuku wo Chikaimashita',
      'آخر بحث',
    ];
    await tester.pumpWidget(_app(_page(recents: recents)));

    final first = find.byKey(const ValueKey<String>('search-recent-Mao'));
    final last = find.byKey(const ValueKey<String>('search-recent-آخر بحث'));
    final firstRect = tester.getRect(first);
    for (final query in recents) {
      final chip = find.byKey(ValueKey<String>('search-recent-$query'));
      expect(tester.getRect(chip).top, firstRect.top);
      expect(tester.getRect(chip).height, firstRect.height);
    }
    expect(firstRect.right, lessThanOrEqualTo(320));
    expect(firstRect.right, greaterThan(280));
    expect(tester.getRect(last).right, lessThan(0));
    expect(find.text('عمليات البحث الأخيرة'), findsOneWidget);

    final horizontal = find.descendant(
      of: find.byType(SearchStartPage),
      matching: find.byType(Scrollable),
    );
    final state = tester.state<ScrollableState>(horizontal);
    expect(state.axisDirection, AxisDirection.left);
    expect(state.position.pixels, 0);
    await tester.drag(horizontal, const Offset(1000, 0));
    await tester.pumpAndSettle();
    expect(state.position.pixels, greaterThan(0));
    expect(last.hitTestable(), findsOneWidget);
    await tester.drag(horizontal, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(first.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long recent searches stay single-line and retain their query', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const query = 'Buchigire Reijou wa Houfuku wo Chikaimashita\nSeason 2';
    String? ran;
    await tester.pumpWidget(
      _app(_page(recents: const [query], onRecent: (value) => ran = value)),
    );

    final label = tester.widget<Text>(find.text(query));
    expect(label.maxLines, 1);
    expect(label.softWrap, isFalse);
    await tester.tapAt(
      tester.getTopRight(find.text(query)) + const Offset(-8, 8),
    );
    expect(ran, query);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing a recent search does not run it', (tester) async {
    String? ran;
    String? removed;
    await tester.pumpWidget(
      _app(
        SearchStartPage(
          recents: const ['One Piece'],
          onRecent: (value) => ran = value,
          onRemoveRecent: (value) => removed = value,
          onClearRecents: () {},
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.close_rounded));
    expect(removed, 'One Piece');
    expect(ran, isNull);
  });

  testWidgets('recent-search chips remain keyboard accessible', (tester) async {
    String? ran;
    await tester.pumpWidget(
      _app(
        _page(recents: const ['One Piece'], onRecent: (value) => ran = value),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(ran, 'One Piece');
  });

  test('MyAnimeList ids are read from a Jikan list, in order', () {
    expect(
      malIdsFromJikanList(<String, dynamic>{
        'data': <Object?>[
          <String, dynamic>{'mal_id': 52991},
          <String, dynamic>{'mal_id': '5114'},
          <String, dynamic>{'mal_id': 52991},
          <String, dynamic>{'title': 'no id'},
        ],
      }),
      <int>[52991, 5114],
    );
    expect(malIdsFromJikanList(null), isEmpty);
  });

  test('MyAnimeList ids are read from an AniList page, in order', () {
    expect(
      malIdsFromAniListPage(<String, dynamic>{
        'data': <String, dynamic>{
          'Page': <String, dynamic>{
            'media': <Object?>[
              <String, dynamic>{'idMal': 21},
              <String, dynamic>{'idMal': null},
              <String, dynamic>{'idMal': 52991},
            ],
          },
        },
      }),
      <int>[21, 52991],
    );
  });

  testWidgets(
    'recent searches share the catalogue scroll instead of covering it',
    (tester) async {
      await tester.pumpWidget(
        _app(
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _page(recents: const ['One Piece'])),
              const SliverToBoxAdapter(child: Text('Catalogue result')),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Catalogue result'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Catalogue result')).dy,
        greaterThan(tester.getBottomLeft(find.text('One Piece')).dy),
      );
      final scrollables = tester.widgetList<Scrollable>(
        find.byType(Scrollable),
      );
      expect(
        scrollables.where((scrollable) => scrollable.axis == Axis.vertical),
        hasLength(1),
      );
    },
  );
}
