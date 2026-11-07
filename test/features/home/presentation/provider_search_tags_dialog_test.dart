import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/features/home/presentation/widgets/provider_search_filter_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openTags(
  WidgetTester tester, {
  ProviderSearchFilterOptions options = const ProviderSearchFilterOptions(
    tags: ['بطل مضاد', 'سفر عبر الزمن'],
  ),
  ProviderSearchFilters initial = const ProviderSearchFilters(),
  ValueChanged<ProviderSearchFilters?>? onResult,
  bool withManga = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final value = await showDialog<ProviderSearchFilters>(
                context: context,
                builder: (_) => ProviderSearchFilterDialog(
                  options: options,
                  initialValue: initial,
                  categories: withManga
                      ? const [
                          ProviderSearchFilterCategory(
                            value: 'anime',
                            label: 'Anime',
                            icon: Icons.movie,
                          ),
                          ProviderSearchFilterCategory(
                            value: 'manga',
                            label: 'Manga',
                            icon: Icons.book,
                          ),
                        ]
                      : const [],
                  category: withManga ? 'anime' : null,
                  optionsFor: (_) async =>
                      const ProviderSearchFilterOptions(genres: ['أكشن']),
                ),
              );
              onResult?.call(value);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tags apply independently from genres and preserve sorting', (
    tester,
  ) async {
    ProviderSearchFilters? result;
    await openTags(
      tester,
      initial: const ProviderSearchFilters(sort: 'year_desc'),
      onResult: (value) => result = value,
    );
    expect(find.byKey(const ValueKey('filterCard-tags')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('filterChip-بطل مضاد')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('filterApply')));
    await tester.pumpAndSettle();
    expect(result?.tags, {'بطل مضاد'});
    expect(result?.genres, isEmpty);
    expect(result?.sort, 'year_desc');
  });
  testWidgets('reset clears tag selection', (tester) async {
    ProviderSearchFilters? result;
    await openTags(
      tester,
      initial: const ProviderSearchFilters(tags: {'بطل مضاد'}),
      onResult: (value) => result = value,
    );
    await tester.tap(find.byKey(const ValueKey('filterReset')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('filterApply')));
    await tester.pumpAndSettle();
    expect(result?.tags, isEmpty);
    expect(result?.count, 0);
  });
  testWidgets(
    'Rift tags are dropped when the manga category does not offer them',
    (tester) async {
      ProviderSearchFilters? result;
      await openTags(
        tester,
        withManga: true,
        options: const ProviderSearchFilterOptions(
          tags: ['بطل مضاد'],
          genres: ['أكشن'],
        ),
        initial: const ProviderSearchFilters(
          tags: {'بطل مضاد'},
          genres: {'أكشن'},
        ),
        onResult: (value) => result = value,
      );
      await tester.tap(find.byKey(const ValueKey('filterCategory-manga')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filterCard-tags')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('filterApply')));
      await tester.pumpAndSettle();
      expect(result?.tags, isEmpty);
      expect(result?.genres, {'أكشن'});
    },
  );
  testWidgets(
    'large tag sets start bounded while keeping a previous selection visible',
    (tester) async {
      await openTags(
        tester,
        options: ProviderSearchFilterOptions(
          tags: [for (var i = 0; i < 342; i++) 'tag$i'],
        ),
        initial: const ProviderSearchFilters(tags: {'tag341'}),
      );
      expect(find.byKey(const ValueKey('filterChip-tag341')), findsOneWidget);
      expect(find.byKey(const ValueKey('filterChip-tag100')), findsNothing);
      final more = find.byKey(const ValueKey('filter-tags-more'));
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filterChip-tag100')), findsOneWidget);
    },
  );
}
