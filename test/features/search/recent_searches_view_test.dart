import 'package:animewitcher/features/search/presentation/widgets/recent_searches_view.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('ar'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  const searches = <String>[
    'Buchigire Reijou wa Houfuku wo Chikaimashita',
    'One Piece',
    'Mao',
  ];

  testWidgets('lists every recent search, newest first', (tester) async {
    await tester.pumpWidget(
      _app(
        RecentSearchesView(
          searches: searches,
          onSelected: (_) {},
          onRemoved: (_) {},
          onClearAll: () {},
        ),
      ),
    );

    expect(find.text('عمليات البحث الأخيرة'), findsOneWidget);
    for (final query in searches) {
      expect(find.text(query), findsOneWidget);
    }

    // Order on screen matches the order given.
    final first = tester.getTopLeft(find.text(searches.first)).dy;
    final last = tester.getTopLeft(find.text(searches.last)).dy;
    expect(first, lessThan(last));
  });

  testWidgets('a long title is kept to one line rather than wrapping', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _app(
        RecentSearchesView(
          searches: searches,
          onSelected: (_) {},
          onRemoved: (_) {},
          onClearAll: () {},
        ),
      ),
    );

    final title = tester.widget<Text>(find.text(searches.first));
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull, reason: 'no overflow on a phone');
  });

  testWidgets('tapping one runs it', (tester) async {
    String? chosen;
    await tester.pumpWidget(
      _app(
        RecentSearchesView(
          searches: searches,
          onSelected: (value) => chosen = value,
          onRemoved: (_) {},
          onClearAll: () {},
        ),
      ),
    );

    await tester.tap(find.text('One Piece'));
    await tester.pump();
    expect(chosen, 'One Piece');
  });

  testWidgets('the x removes just that one', (tester) async {
    String? removed;
    await tester.pumpWidget(
      _app(
        RecentSearchesView(
          searches: searches,
          onSelected: (_) {},
          onRemoved: (value) => removed = value,
          onClearAll: () {},
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('recent-search-remove-Mao')),
    );
    await tester.pump();
    expect(removed, 'Mao');
  });

  testWidgets('removing does not also run the search', (tester) async {
    // The x sits inside the row that runs a search when tapped, so it has to
    // swallow the tap rather than doing both.
    String? chosen;
    String? removed;
    await tester.pumpWidget(
      _app(
        RecentSearchesView(
          searches: searches,
          onSelected: (value) => chosen = value,
          onRemoved: (value) => removed = value,
          onClearAll: () {},
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('recent-search-remove-One Piece')),
    );
    await tester.pump();
    expect(removed, 'One Piece');
    expect(chosen, isNull);
  });

  testWidgets('clear all is offered once', (tester) async {
    var cleared = 0;
    await tester.pumpWidget(
      _app(
        RecentSearchesView(
          searches: searches,
          onSelected: (_) {},
          onRemoved: (_) {},
          onClearAll: () => cleared += 1,
        ),
      ),
    );

    expect(find.text('مسح الكل'), findsOneWidget);
    await tester.tap(find.text('مسح الكل'));
    await tester.pump();
    expect(cleared, 1);
  });
}
