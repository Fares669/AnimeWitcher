import 'package:animewitcher/core/account/animewitcher_character_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_instant_results.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item(
  String title, {
  MultimediaContentType type = MultimediaContentType.series,
  int? year,
  double? score,
  String? description,
}) => MultimediaItem(
  title: title,
  url: 'https://example.test/${Uri.encodeComponent(title)}',
  posterUrl: '',
  contentType: type,
  year: year,
  score: score,
  description: description,
);

Widget _app(Widget child) => ProviderScope(
  child: MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  ),
);

void main() {
  final items = <MultimediaItem>[
    _item('Naruto', year: 2002, score: 8.4, description: 'A young ninja.'),
    _item('Naruto: Shippuuden', year: 2007, score: 8.5),
    _item(
      'The Last: Naruto the Movie',
      type: MultimediaContentType.movie,
      year: 2014,
    ),
    _item('Bleach', year: 2004),
  ];

  test('a series is known by the name before its colon or season', () {
    expect(SearchInstantResults.seriesNameOf('Naruto: Shippuuden'), 'naruto');
    expect(
      SearchInstantResults.seriesNameOf('Jujutsu Kaisen Season 2'),
      'jujutsu kaisen',
    );
    expect(
      SearchInstantResults.sameSeries(items.first, items).map((i) => i.title),
      ['Naruto: Shippuuden', 'The Last: Naruto the Movie'],
    );
  });

  testWidgets('the best match leads, with its series and the rest grouped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    MultimediaItem? opened;
    var seeAll = false;
    await tester.pumpWidget(
      _app(
        SearchInstantResults(
          items: items,
          loading: false,
          onOpen: (item) => opened = item,
          onSeeAll: () => seeAll = true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('search-instant-top')), findsOneWidget);
    expect(find.text('أفضل نتيجة'), findsOneWidget);
    // Synopses are left out to keep the panel small.
    expect(find.text('A young ninja.'), findsNothing);
    expect(
      find.byKey(const ValueKey('search-instant-related')),
      findsOneWidget,
    );
    expect(find.text('مسلسلات'), findsWidgets);
    expect(find.text('أفلام'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('search-instant-open')));
    expect(opened?.title, 'Naruto');

    await tester.tap(find.byKey(const ValueKey('search-instant-see-all')));
    expect(seeAll, isTrue);

    // The films tab: only films, the film now the best match.
    await tester.tap(find.byKey(const ValueKey('search-instant-tab-movies')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('search-instant-open')));
    expect(opened?.title, 'The Last: Naruto the Movie');
    expect(tester.takeException(), isNull);
  });

  testWidgets('searching everything shows manga and characters too', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    AnimeWitcherCharacterHit? character;
    await tester.pumpWidget(
      _app(
        SearchInstantResults(
          items: items,
          manga: [_item('Naruto (manga)', type: MultimediaContentType.manga)],
          characters: const [
            AnimeWitcherCharacterHit(id: 'c1', name: 'Uzumaki Naruto'),
          ],
          onOpenCharacter: (hit) => character = hit,
          loading: false,
          onOpen: (_) {},
          onSeeAll: () {},
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('search-instant-tab-manga')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('search-instant-tab-characters')),
      findsOneWidget,
    );
    expect(find.text('مانجا'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('search-instant-character-c1')));
    expect(character?.name, 'Uzumaki Naruto');
    expect(tester.takeException(), isNull);
  });
}
