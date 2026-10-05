import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_start_page.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
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
  ValueChanged<MultimediaItem>? onOpen,
}) => SearchStartPage(
  recents: recents,
  onRecent: onRecent ?? (_) {},
  onRemoveRecent: (_) {},
  onClearRecents: () {},
  onOpen: onOpen ?? (_) {},
);

void main() {
  test('an empty start page says so, so search can show its invitation', () {
    expect(_page().hasAnything, isFalse);
    expect(_page(recents: const ['Mao']).hasAnything, isTrue);
  });

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
          onOpen: (_) {},
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

  testWidgets('surprise me is offered and asks for a pick', (tester) async {
    var asked = 0;
    await tester.pumpWidget(
      _app(
        SearchStartPage(
          recents: const <String>[],
          onRecent: (_) {},
          onRemoveRecent: (_) {},
          onClearRecents: () {},
          onOpen: (_) {},
          onSurprise: () => asked++,
        ),
      ),
    );
    expect(
      _page().hasAnything,
      isFalse,
      reason: 'without the button an empty page still says so',
    );
    await tester.tap(find.byKey(const ValueKey<String>('search-surprise')));
    expect(asked, 1);
  });

  testWidgets('the top ten is numbered and opens what is tapped', (
    tester,
  ) async {
    MultimediaItem? opened;
    final top = <MultimediaItem>[
      for (var i = 1; i <= 3; i++)
        MultimediaItem(
          title: 'Show $i',
          url: 'https://example.test/$i',
          posterUrl: '',
          contentType: MultimediaContentType.anime,
        ),
    ];
    await tester.pumpWidget(
      _app(
        SearchStartPage(
          recents: const <String>[],
          onRecent: (_) {},
          onRemoveRecent: (_) {},
          onClearRecents: () {},
          onOpen: (item) => opened = item,
          topTen: top,
          notStarted: [top.last],
        ),
      ),
    );
    expect(find.text('الأكثر رواجًا هذا الأسبوع'), findsOneWidget);
    expect(find.text('في قائمتك ولم تبدأه'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('search-top-ten-2')));
    expect(opened?.title, 'Show 2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the best rated films and shows get rows with view all', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    MultimediaItem? opened;
    var viewAll = 0;
    MultimediaItem show(String name) => MultimediaItem(
      title: name,
      url: 'https://example.test/$name',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
    );
    final page = SearchStartPage(
      recents: const <String>[],
      onRecent: (_) {},
      onRemoveRecent: (_) {},
      onClearRecents: () {},
      onOpen: (item) => opened = item,
      topMovies: [show('Film')],
      onTopMoviesViewAll: () => viewAll += 10,
      topRated: [show('Best')],
      onTopRatedViewAll: () => viewAll++,
    );
    expect(page.hasAnything, isTrue);
    await tester.pumpWidget(_app(page));

    expect(find.text('أفضل الأفلام'), findsOneWidget);
    expect(find.text('الأعلى تقييمًا'), findsOneWidget);
    await tester.tap(find.text('عرض الكل').first);
    await tester.tap(find.text('عرض الكل').last);
    expect(viewAll, 11);
    await tester.tap(
      find.byKey(
        const ValueKey<String>('search-top-movies-https://example.test/Film'),
      ),
    );
    expect(opened?.title, 'Film');
    expect(tester.takeException(), isNull);
  });
}
