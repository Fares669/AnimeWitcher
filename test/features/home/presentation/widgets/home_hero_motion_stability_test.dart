import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/home/presentation/widgets/home_hero_carousel.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/fallback_poster_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

void main() {
  testWidgets(
    'Home hero reuses artwork during motion and responds to quality changes',
    (tester) async {
      final scroll = ScrollController();
      final visibility = VisibilityDetectorController.instance;
      final originalInterval = visibility.updateInterval;
      final originalQuality = highQualityArtwork.value;
      final originalFallback = artworkFallbackEnabled.value;
      visibility.updateInterval = Duration.zero;
      highQualityArtwork.value = true;
      artworkFallbackEnabled.value = false;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 720);
      addTearDown(() {
        scroll.dispose();
        visibility.updateInterval = originalInterval;
        highQualityArtwork.value = originalQuality;
        artworkFallbackEnabled.value = originalFallback;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final artwork = find.byType(FallbackPosterImage);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            deviceProfileProvider.overrideWith(
              (_) async => DeviceProfile(isDesktopOS: true),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                controller: scroll,
                slivers: [
                  SliverToBoxAdapter(
                    child: HomeHeroCarousel(
                      scrollController: scroll,
                      movies: [
                        for (var i = 0; i < 2; i++)
                          MultimediaItem(
                            title: 'Hero slide $i',
                            url: 'https://example.test/title-$i',
                            posterUrl: '',
                          ),
                      ],
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 1500)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final original = tester.widget<FallbackPosterImage>(artwork);
      for (final offset in [24.0, 72.0, 132.0, 0.0]) {
        scroll.jumpTo(offset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<FallbackPosterImage>(artwork), same(original));
      }

      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final moving = tester.widgetList<FallbackPosterImage>(artwork).toList();
      expect(moving, hasLength(2));
      await tester.pump(const Duration(milliseconds: 64));
      expect(tester.widgetList<FallbackPosterImage>(artwork).toList(), [
        same(moving.first),
        same(moving.last),
      ]);

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.text('Hero slide 1'), findsWidgets);
      expect(find.text('Hero slide 0'), findsNothing);
      expect(tester.widget<FallbackPosterImage>(artwork).memCacheWidth, 1536);
      highQualityArtwork.value = false;
      await tester.pump();
      expect(tester.widget<FallbackPosterImage>(artwork).memCacheWidth, 1200);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
