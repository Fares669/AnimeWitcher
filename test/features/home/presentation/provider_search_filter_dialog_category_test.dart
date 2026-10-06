import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/features/home/presentation/widgets/provider_search_filter_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const categories = <ProviderSearchFilterCategory>[
    ProviderSearchFilterCategory(
      value: 'anime',
      label: 'Anime',
      icon: Icons.movie_rounded,
    ),
    ProviderSearchFilterCategory(
      value: 'manga',
      label: 'Manga',
      icon: Icons.menu_book_rounded,
    ),
  ];

  Future<ProviderSearchFilters?> openSheet(
    WidgetTester tester, {
    required ValueChanged<String> onCategoryApplied,
  }) async {
    ProviderSearchFilters? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<ProviderSearchFilters>(
                  context: context,
                  builder: (_) => ProviderSearchFilterDialog(
                    options: const ProviderSearchFilterOptions(
                      genres: <String>['Action', 'Drama'],
                    ),
                    initialValue: const ProviderSearchFilters(),
                    categories: categories,
                    category: 'anime',
                    optionsFor: (category) async =>
                        const ProviderSearchFilterOptions(),
                    onCategoryApplied: onCategoryApplied,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('the sheet picks the category, and one without filters says so', (
    tester,
  ) async {
    String? applied;
    await openSheet(tester, onCategoryApplied: (value) => applied = value);

    // Anime opens on its own filters.
    expect(find.byKey(const ValueKey('filterCategory-anime')), findsOneWidget);
    expect(find.text('Action'), findsOneWidget);
    expect(find.text('This section has no filters'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('filterCategory-manga')));
    await tester.pumpAndSettle();

    expect(find.text('Action'), findsNothing);
    expect(find.text('This section has no filters'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filterApply')));
    await tester.pumpAndSettle();

    expect(applied, 'manga');
  });

  testWidgets('closing without applying keeps the category', (tester) async {
    String? applied;
    await openSheet(tester, onCategoryApplied: (value) => applied = value);

    await tester.tap(find.byKey(const ValueKey('filterCategory-manga')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filterBack')));
    await tester.pumpAndSettle();

    expect(applied, isNull);
  });

  testWidgets('choices a category does not offer are dropped on apply', (
    tester,
  ) async {
    ProviderSearchFilters? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<ProviderSearchFilters>(
                  context: context,
                  builder: (_) => ProviderSearchFilterDialog(
                    options: const ProviderSearchFilterOptions(
                      genres: <String>['Action'],
                      types: <String>['TV'],
                    ),
                    // An anime type chosen earlier, and a shared genre.
                    initialValue: const ProviderSearchFilters(
                      genres: {'Action'},
                      types: {'TV'},
                    ),
                    categories: categories,
                    category: 'anime',
                    optionsFor: (category) async =>
                        const ProviderSearchFilterOptions(
                          genres: <String>['Action'],
                          types: <String>['Manhwa'],
                        ),
                    onCategoryApplied: (_) {},
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('filterCategory-manga')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filterApply')));
    await tester.pumpAndSettle();

    expect(result?.genres, {'Action'}, reason: 'manga has this genre too');
    expect(result?.types, isEmpty, reason: 'TV is not a manga type');
  });

  testWidgets('a category without filters can say why', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<ProviderSearchFilters>(
                context: context,
                builder: (_) => ProviderSearchFilterDialog(
                  options: const ProviderSearchFilterOptions(),
                  initialValue: const ProviderSearchFilters(),
                  categories: const <ProviderSearchFilterCategory>[
                    ProviderSearchFilterCategory(
                      value: 'characters',
                      label: 'Characters',
                      icon: Icons.groups_rounded,
                      noFiltersNote: 'Search characters by name.',
                    ),
                  ],
                  category: 'characters',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Search characters by name.'), findsOneWidget);
    expect(find.text('This section has no filters'), findsNothing);
  });

  testWidgets('on a narrow phone every category is in view and years go '
      'five to a row', (tester) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const six = <ProviderSearchFilterCategory>[
      ProviderSearchFilterCategory(
        value: 'all',
        label: 'All',
        icon: Icons.apps,
      ),
      ProviderSearchFilterCategory(
        value: 'anime',
        label: 'Anime',
        icon: Icons.tv,
      ),
      ProviderSearchFilterCategory(
        value: 'animation',
        label: 'Animation',
        icon: Icons.brush,
      ),
      ProviderSearchFilterCategory(
        value: 'manga',
        label: 'Manga',
        icon: Icons.book,
      ),
      ProviderSearchFilterCategory(
        value: 'characters',
        label: 'Characters',
        icon: Icons.groups,
      ),
      ProviderSearchFilterCategory(
        value: 'people',
        label: 'People',
        icon: Icons.person,
      ),
    ];
    final years = [for (var y = 2028; y >= 2010; y--) '$y'];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<ProviderSearchFilters>(
                context: context,
                builder: (_) => ProviderSearchFilterDialog(
                  options: ProviderSearchFilterOptions(years: years),
                  initialValue: const ProviderSearchFilters(),
                  categories: six,
                  category: 'anime',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    for (final category in six) {
      final rect = tester.getRect(
        find.byKey(ValueKey('filterCategory-${category.value}')),
      );
      expect(rect.left, greaterThanOrEqualTo(0), reason: category.value);
      expect(rect.right, lessThanOrEqualTo(360), reason: category.value);
    }

    // 2028 to 2024 on one row; the rest wait behind "show more".
    final top = tester
        .getRect(find.byKey(const ValueKey('filterChip-2028')))
        .top;
    for (var y = 2024; y <= 2028; y++) {
      expect(tester.getRect(find.byKey(ValueKey('filterChip-$y'))).top, top);
    }
    expect(find.byKey(const ValueKey('filterChip-2023')), findsNothing);
    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('filterChip-2023')), findsOneWidget);
  });

  testWidgets('release years animate between collapsed and expanded heights', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final years = [for (var y = 2028; y >= 2019; y--) '$y'];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<ProviderSearchFilters>(
                context: context,
                builder: (_) => ProviderSearchFilterDialog(
                  options: ProviderSearchFilterOptions(years: years),
                  initialValue: const ProviderSearchFilters(),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final yearCard = find.byKey(const ValueKey('filterCard-year'));
    final collapsed = tester.getSize(yearCard).height;
    await tester.tap(find.text('Show more'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final midway = tester.getSize(yearCard).height;
    await tester.pumpAndSettle();
    final expanded = tester.getSize(yearCard).height;

    expect(expanded, greaterThan(collapsed));
    expect(midway, greaterThan(collapsed));
    expect(midway, lessThan(expanded));
  });

  testWidgets('on a phone the filters rise as a full-screen sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ProviderSearchFilters? result;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 47, bottom: 34),
          ),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showProviderSearchFilterSheet(
                  context: context,
                  builder: (_) => const ProviderSearchFilterDialog(
                    options: ProviderSearchFilterOptions(
                      genres: <String>['Action'],
                    ),
                    initialValue: ProviderSearchFilters(),
                    asSheet: true,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    final sheet = tester.getRect(find.byType(BottomSheet));
    expect(sheet.top, 47);
    expect(sheet.bottom, 800);
    await tester.tap(find.byKey(const ValueKey('filterChip-Action')));
    await tester.tap(find.byKey(const ValueKey('filterApply')));
    await tester.pumpAndSettle();
    expect(result?.genres, {'Action'});
  });
}
