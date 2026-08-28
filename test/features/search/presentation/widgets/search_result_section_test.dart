import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_result_section.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/catalog_ltr.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:animewitcher/shared/widgets/shimmer_placeholder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

MultimediaItem _item() {
  return MultimediaItem(
    title: 'Bleach',
    url: 'https://example.test/bleach',
    posterUrl: '',
    catalogType: 'مسلسل',
    year: 2004,
  );
}

void main() {
  testWidgets(
    'search result cards use the same poster shimmer as other pages',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CatalogLtr(
                child: CustomScrollView(
                  slivers: [
                    SearchResultSection(
                      providerName: 'AnimeWitcher',
                      providerId: 'native',
                      results: [_item()],
                      isLoadingMore: false,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump();

      final card = tester.widget<MultimediaCard>(find.byType(MultimediaCard));
      expect(card.showImageLoadingShimmer, isTrue);
    },
  );

  testWidgets('search appends the same shimmer tiles used on other grids', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CatalogLtr(
              child: CustomScrollView(
                slivers: [
                  SearchResultSection(
                    providerName: 'AnimeWitcher',
                    providerId: 'native',
                    results: [_item()],
                    isLoadingMore: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(find.byType(ShimmerPlaceholder), findsWidgets);
  });

  testWidgets('search result cards fill left to right in Arabic', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: CatalogLtr(
              child: CustomScrollView(
                slivers: [
                  SearchResultSection(
                    providerName: 'AnimeWitcher',
                    providerId: 'native',
                    results: [
                      MultimediaItem(
                        title: 'First',
                        url: 'https://example.test/first',
                        posterUrl: '',
                      ),
                      MultimediaItem(
                        title: 'Second',
                        url: 'https://example.test/second',
                        posterUrl: '',
                      ),
                      MultimediaItem(
                        title: 'Third',
                        url: 'https://example.test/third',
                        posterUrl: '',
                      ),
                    ],
                    isLoadingMore: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    final first = tester.getTopLeft(
      find.byKey(const ValueKey('https://example.test/first')),
    );
    final third = tester.getTopLeft(
      find.byKey(const ValueKey('https://example.test/third')),
    );
    expect(first.dx, lessThan(third.dx));
  });
}
