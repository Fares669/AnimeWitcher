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

  testWidgets('recent searches share the catalogue scroll instead of covering it', (
    tester,
  ) async {
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
    expect(find.byType(Scrollable), findsOneWidget);
  });
}
