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

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(applied, 'manga');
  });

  testWidgets('closing without applying keeps the category', (tester) async {
    String? applied;
    await openSheet(tester, onCategoryApplied: (value) => applied = value);

    await tester.tap(find.byKey(const ValueKey('filterCategory-manga')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close_rounded));
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
    await tester.tap(find.text('Apply'));
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
}
