import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/coming_soon_screen.dart';
import 'package:animewitcher/shared/widgets/anime_catalog_shimmer.dart';
import 'package:animewitcher/shared/widgets/app_page_header.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

class _HangingProvider extends AnimeWitcherNativeProvider {
  _HangingProvider() : super(Dio(), SettingsRepository(_MemoryStorage()));

  final Completer<ProviderMediaPage> gate = Completer<ProviderMediaPage>();

  @override
  Future<ProviderMediaPage> getUpcomingPage({int offset = 0}) => gate.future;
}

void main() {
  testWidgets(
    'coming soon cards use their own layer without an outer duplicate',
    (tester) async {
      final provider = _HangingProvider();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [activeProviderProvider.overrideWithValue(provider)],
          child: const MaterialApp(home: ComingSoonScreen()),
        ),
      );
      provider.gate.complete(
        ProviderMediaPage(
          items: [
            MultimediaItem(
              title: 'Upcoming fixture',
              url: 'https://fixture.test/upcoming',
              posterUrl: '',
            ),
          ],
          nextOffset: 1,
          hasMore: false,
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byType(MultimediaCard);
      expect(card, findsOneWidget);
      int count = 0;
      RenderObject? layer = tester.renderObject<RenderObject>(card).parent;
      while (layer != null && layer is! RenderSliverGrid) {
        if (layer is RenderRepaintBoundary) count++;
        layer = layer.parent;
      }
      debugPrint('COMING_PROFILE $count outer repaint boundaries per card');
      expect(count, 0);
      expect(layer, isA<RenderSliverGrid>());
      expect(
        find.descendant(of: card, matching: find.byType(RepaintBoundary)),
        findsWidgets,
      );
    },
  );

  testWidgets('coming soon loading posters start below the header', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final provider = _HangingProvider();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [activeProviderProvider.overrideWithValue(provider)],
        child: const MaterialApp(home: ComingSoonScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(AnimeCatalogShimmer), findsOneWidget);
    final context = tester.element(find.byType(ComingSoonScreen));
    final headerTop = appPageHeaderContentTopInset(context);
    final poster = tester.getRect(find.byType(AnimePosterShimmer).first);
    // Like the favorite characters page: the first loading card sits
    // below the header strip, not up behind it.
    expect(poster.top, greaterThanOrEqualTo(headerTop));
    expect(tester.takeException(), isNull);
  });
}
