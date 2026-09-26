import 'package:animewitcher/features/search/presentation/search_provider.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_header_bar.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final class _IdleSearchNotifier extends PagedSearchNotifier {
  @override
  SearchAggregateState build() => const SearchAggregateState();
}

void main() {
  testWidgets('iOS puts the search actions where every platform does', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
    await tester.binding.setSurfaceSize(const Size(428, 300));

    final controller = TextEditingController();
    final searchFocus = FocusNode();
    final clearFocus = FocusNode();
    Future<Rect> actionsOn(TargetPlatform platform) async {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            searchPagedResultsProvider.overrideWith(_IdleSearchNotifier.new),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(428, 300),
                padding: EdgeInsets.only(right: 59),
              ),
              child: Scaffold(
                body: SearchHeaderBar(
                  textController: controller,
                  searchFocusNode: searchFocus,
                  clearButtonFocusNode: clearFocus,
                  onSubmitted: (_) {},
                  onChanged: (_) {},
                  onShowFilters: () {},
                  onSortSelected: (_) {},
                  sortValue: 'favorites',
                  sortItems: const <AppleNativeMenuItem>[
                    AppleNativeMenuItem(
                      value: 'favorites',
                      label: 'Favorites',
                      systemImage: 'star.fill',
                    ),
                  ],
                  sortIcon: Icons.star_rounded,
                  sortSystemImage: 'star.fill',
                  sortTooltip: 'Sort',
                  activeFilterCount: 0,
                  isFilterLoading: false,
                  showSort: true,
                  showFilter: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getRect(
        find.byKey(const ValueKey('search-action-capsule')),
      );
    }

    try {
      // The native glass header iOS once lined up with is retired: iOS lays
      // the bar out as every other platform does.
      final ios = await actionsOn(TargetPlatform.iOS);
      final android = await actionsOn(TargetPlatform.android);
      expect(ios, android);
    } finally {
      controller.dispose();
      searchFocus.dispose();
      clearFocus.dispose();
      debugDefaultTargetPlatformOverride = null;
      await tester.binding.setSurfaceSize(null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      );
    }
  });

  testWidgets(
    'character search header keeps only the filter action, which picks the category',
    (tester) async {
      final controller = TextEditingController();
      final searchFocus = FocusNode();
      final clearFocus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(searchFocus.dispose);
      addTearDown(clearFocus.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            searchPagedResultsProvider.overrideWith(_IdleSearchNotifier.new),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SearchHeaderBar(
                textController: controller,
                searchFocusNode: searchFocus,
                clearButtonFocusNode: clearFocus,
                onSubmitted: (_) {},
                onChanged: (_) {},
                onShowFilters: () {},
                onSortSelected: (_) {},
                sortValue: 'favorites',
                sortItems: const <AppleNativeMenuItem>[
                  AppleNativeMenuItem(value: 'favorites', label: 'Favorites'),
                ],
                sortIcon: Icons.star_rounded,
                sortSystemImage: 'star.fill',
                sortTooltip: 'Sort',
                activeFilterCount: 2,
                isFilterLoading: false,
                showSort: false,
                showFilter: true,
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.byTooltip('Search domain'), findsNothing);
      expect(find.byTooltip('Sort'), findsNothing);
      expect(find.byTooltip('الفلاتر'), findsOneWidget);
    },
  );
}
