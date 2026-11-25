import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_desktop_hero.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/fallback_poster_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('wide Details retains banner artwork until its inputs change', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    final quality = highQualityArtwork.value;
    final fallback = artworkFallbackEnabled.value;
    highQualityArtwork.value = true;
    artworkFallbackEnabled.value = false;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      highQualityArtwork.value = quality;
      artworkFallbackEnabled.value = fallback;
    });

    final page = ValueNotifier((title: 'An offline title', selected: 0));
    addTearDown(page.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: page,
              builder: (context, value, _) {
                final item = MultimediaItem(
                  title: value.title,
                  url: 'https://example.test/the-title',
                  posterUrl: '',
                );
                return DetailsDesktopHero(
                  displayItem: item,
                  details: item,
                  detailsState: AsyncValue.data(item),
                  isMovie: false,
                  itemUrl: item.url,
                  onRefresh: () async {},
                  heroActions: Text('Selected: ${value.selected}'),
                );
              },
            ),
          ),
        ),
      ),
    );
    final artwork = find.byType(FallbackPosterImage);
    final original = tester.widget<FallbackPosterImage>(artwork);
    expect(original.memCacheWidth, 1600);
    page.value = (title: page.value.title, selected: 2);
    await tester.pump();
    expect(find.text('Selected: 2'), findsOneWidget);
    expect(tester.widget<FallbackPosterImage>(artwork), same(original));

    page.value = (title: 'A revised title', selected: 2);
    await tester.pump();
    final updated = tester.widget<FallbackPosterImage>(artwork);
    expect(updated, isNot(same(original)));
    expect(updated.title, 'A revised title');

    highQualityArtwork.value = false;
    await tester.pump();
    expect(tester.widget<FallbackPosterImage>(artwork).memCacheWidth, 1280);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
