import 'package:animewitcher/features/search/presentation/search_domain.dart';
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
  testWidgets('iOS three-action glass keeps the same 34pt trailing coordinate', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.binding.setSurfaceSize(const Size(428, 300));

    final controller = TextEditingController();
    final searchFocus = FocusNode();
    final clearFocus = FocusNode();
    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            searchPagedResultsProvider.overrideWith(_IdleSearchNotifier.new),
          ],
          child: MaterialApp(
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
                domain: SearchDomain.anime,
                onDomainSelected: (_) {},
                showSort: true,
                showFilter: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final actionRect = tester.getRect(
        find.byKey(const ValueKey('search-action-capsule')),
      );
      expect(428 - actionRect.right, 34);
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

  testWidgets('character search header keeps only the domain action', (
    tester,
  ) async {
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
              domain: SearchDomain.characters,
              onDomainSelected: (_) {},
              showSort: false,
              showFilter: false,
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.byTooltip('Search domain'), findsOneWidget);
    expect(find.byTooltip('Sort'), findsNothing);
    expect(find.byTooltip('الفلاتر'), findsNothing);
  });
}
