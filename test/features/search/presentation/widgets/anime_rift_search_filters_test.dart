import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/features/home/presentation/widgets/provider_search_filter_dialog.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_sort_dialog.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_action_buttons.dart';
import 'package:animewitcher/shared/widgets/animated_sort_menu_button.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Rift shows one reverse button outside the six sort rows', (
    tester,
  ) async {
    var reversed = 0;
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SearchActionButtons(
              sortValue: 'release_year',
              sortItems: [
                for (final field in RiftSearchSortField.values)
                  AppleNativeMenuItem(
                    value: field.value,
                    label: field.arabic,
                    icon: field.icon,
                  ),
              ],
              onSortSelected: (value) => selected = value,
              onReverseSort: () => reversed++,
              onFilterPressed: () {},
              sortTooltip: 'Rift sort',
              filterTooltip: 'Filter',
              sortIcon: Icons.calendar_month_rounded,
              sortSystemImage: 'line.3.horizontal.decrease',
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('rift-reverse-sort')));
    expect(reversed, 1);
    await tester.tap(find.byTooltip('Rift sort'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('reverse-sort-release_year')),
      findsNothing,
    );
    expect(find.text('التقييم'), findsOneWidget);
    expect(
      RiftSearchSortField.values.map((field) => field.icon).toSet(),
      hasLength(RiftSearchSortField.values.length),
    );
    await tester.tap(find.text('التقييم'));
    await tester.pumpAndSettle();
    expect(selected, 'rating');
    expect(reversed, 1);
  });

  testWidgets('AnimeRift season and country work without selecting a year', (
    tester,
  ) async {
    ProviderSearchFilters? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  saved = await showDialog<ProviderSearchFilters>(
                    context: context,
                    builder: (_) => const ProviderSearchFilterDialog(
                      options: ProviderSearchFilterOptions(
                        seasons: ['شتاء', 'صيف'],
                        countries: ['اليابان', 'الصين'],
                        years: ['2026'],
                      ),
                      initialValue: ProviderSearchFilters(),
                      allowSeasonWithoutYear: true,
                      category: 'anime',
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
    final season = find.byKey(const ValueKey('filterChip-شتاء'));
    await tester.ensureVisible(season);
    await tester.tap(season);
    await tester.pumpAndSettle();
    final country = find.byKey(const ValueKey('filterChip-الصين'));
    await tester.ensureVisible(country);
    await tester.tap(country);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('filterApply')));
    await tester.pumpAndSettle();
    expect(saved?.seasons, {'شتاء'});
    expect(saved?.countries, {'الصين'});
    expect(saved?.years, isEmpty);
  });

  testWidgets('non-Rift filters still require a year with a season', (
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

  testWidgets('Rift menu has one field and a separate reversing arrow', (
    tester,
  ) async {
    String? picked;
    String? reverse;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: BlurredMenuPanel(
              items: [
                for (final field in RiftSearchSortField.values)
                  AppleNativeMenuItem(value: field.value, label: field.arabic),
              ],
              selectedValue: 'release_year',
              tint: Colors.blue,
              reverseAscending: false,
              onPick: (value) => picked = value,
              onReverseSelected: (value) => reverse = value,
            ),
          ),
        ),
      ),
    );
    expect(RiftSearchSortField.values, hasLength(6));
    expect(find.text('تاريخ الإصدار'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reverse-sort-release_year')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reverse-sort-release_year')));
    expect(reverse, 'release_year');
    expect(picked, isNull);
  });

  testWidgets(
    'the actual sort popup arrow activates reversal, not row selection',
    (tester) async {
      String? picked;
      String? reversed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AnimatedSortMenuButton(
                tooltip: 'Sort',
                selectedValue: 'release_year',
                items: const [
                  AppleNativeMenuItem(
                    value: 'release_year',
                    label: 'تاريخ الإصدار',
                  ),
                  AppleNativeMenuItem(value: 'rating', label: 'التقييم'),
                ],
                onSelected: (value) => picked = value,
                onReverseSelected: (value) => reversed = value,
                reverseAscending: false,
                icon: Icons.sort,
                systemImage: 'arrow.down',
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Sort'));
      await tester.pumpAndSettle();
      final arrow = find.byKey(const ValueKey('reverse-sort-release_year'));
      expect(arrow, findsOneWidget);
      await tester.tap(arrow);
      await tester.pumpAndSettle();
      expect(reversed, 'release_year');
      expect(picked, isNull);
    },
  );

  test('legacy Rift year value maps to a single field', () {
    expect(RiftSearchSortField.selected('year_asc'), 'release_year');
    expect(RiftSearchSortField.selected('year_desc'), 'release_year');
    expect(RiftSearchSortField.selected('title_desc'), 'title');
    expect(
      RiftSearchSortField.selected('recently_updated_asc'),
      'recently_updated',
    );
  });
}
