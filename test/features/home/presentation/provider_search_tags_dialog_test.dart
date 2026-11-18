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
    'Anime tags are dropped when the manga category does not offer them',
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
  testWidgets('AnimeWitcher filters require a year with a season', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<ProviderSearchFilters>(
                context: context,
                builder: (_) => const ProviderSearchFilterDialog(
                  options: ProviderSearchFilterOptions(
                    seasons: ['شتاء'],
                    years: ['2026'],
                  ),
                  initialValue: ProviderSearchFilters(),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filterChip-شتاء')));
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('filterApply')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('اختر سنة مع الموسم'), findsOneWidget);
  });
  testWidgets(
    'studio, source, and version render as expandable chip cards with Show all',
    (tester) async {
      ProviderSearchFilters? result;
      await openTags(
        tester,
        options: ProviderSearchFilterOptions(
          studios: [for (var i = 0; i < 20; i++) 'Studio $i'],
          sources: [for (var i = 0; i < 12; i++) 'Source $i'],
          versions: const ['مترجم', 'مدبلج', 'مترجم ومدبلج'],
        ),
        initial: const ProviderSearchFilters(studios: {'Studio 19'}),
        onResult: (value) => result = value,
      );

      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(find.byKey(const ValueKey('filterCard-studio')), findsOneWidget);
      expect(find.byKey(const ValueKey('filterCard-source')), findsOneWidget);
      expect(find.byKey(const ValueKey('filterCard-version')), findsOneWidget);

      // Selected value stays visible while the rest stay behind "عرض الكل".
      expect(find.byKey(const ValueKey('filterChip-Studio 19')), findsOneWidget);
      expect(find.byKey(const ValueKey('filterChip-Studio 12')), findsNothing);
      expect(find.byKey(const ValueKey('filterChip-Source 11')), findsNothing);

      final moreStudios = find.byKey(const ValueKey('filter-studio-more'));
      await tester.ensureVisible(moreStudios);
      expect(
        find.descendant(of: moreStudios, matching: find.text('عرض الكل')),
        findsOneWidget,
      );
      await tester.tap(moreStudios);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filterChip-Studio 12')), findsOneWidget);

      final moreSources = find.byKey(const ValueKey('filter-source-more'));
      await tester.ensureVisible(moreSources);
      await tester.tap(moreSources);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filterChip-Source 11')), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('filterChip-Source 11')),
      );
      await tester.tap(find.byKey(const ValueKey('filterChip-Source 11')));
      await tester.ensureVisible(
        find.byKey(const ValueKey('filterChip-مدبلج')),
      );
      await tester.tap(find.byKey(const ValueKey('filterChip-مدبلج')));
      await tester.tap(find.byKey(const ValueKey('filterApply')));
      await tester.pumpAndSettle();

      expect(result?.studios, {'Studio 19'});
      expect(result?.sources, {'Source 11'});
      expect(result?.versions, {'مدبلج'});
    },
  );
}
