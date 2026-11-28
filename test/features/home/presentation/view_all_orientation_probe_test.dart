import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/network/poster_cache.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/home/presentation/view_all_screen.dart';
import 'package:animewitcher/features/home/presentation/widgets/media_horizontal_list.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/memory_storage_service.dart';

const _width = 1600;
const _height = 1279;
const _color = ui.Color(0xffb36c27);

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 220 && !ready(); frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(
    ready(),
    isTrue,
    reason: 'decoded image and layout should become ready',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;
  final requests = <String, int>{};

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'view_all_artwork_probe_',
    );
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(_color, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(_width, _height);
    picture.dispose();
    final Uint8List png;
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
    await http.runWithClient(
      () async {
        for (final width in [390.0, 1260.0]) {
          await posterCacheManager.getSingleFile(
            'https://fixture.invalid/poster-$width.png',
          );
        }
      },
      () => MockClient((request) async {
        final url = request.url.toString();
        requests.update(url, (count) => count + 1, ifAbsent: () => 1);
        return http.Response.bytes(
          png,
          200,
          headers: const {
            HttpHeaders.cacheControlHeader: 'max-age=3600',
            HttpHeaders.contentTypeHeader: 'image/png',
          },
        );
      }),
    );
  });

  tearDownAll(() async {
    try {
      await posterCacheManager.dispose();
      await directory.delete(recursive: true);
    } finally {
      PathProviderPlatform.instance = originalPaths;
    }
  });

  for (final size in [const Size(390, 844), const Size(1260, 820)]) {
    testWidgets('real View All uses a small landscape probe at ${size.width}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      imageCache
        ..clear()
        ..clearLiveImages();
      final posterUrl = 'https://fixture.invalid/poster-${size.width}.png';
      // Seed only the shared encoded file. The real View All widgets still
      // own their display-sized decode and orientation probe.
      final originalKey = CachedNetworkImageProvider(posterUrl);
      final first = MultimediaItem(
        title: 'أول عمل في القائمة',
        url: 'https://animewitcher.com/watch/probe-first',
        posterUrl: posterUrl,
      );
      final seeded = [
        first,
        for (var i = 1; i < 30; i++)
          MultimediaItem(
            title: 'عمل $i',
            url: 'https://animewitcher.com/watch/probe-$i',
            posterUrl: posterUrl,
          ),
      ];
      final offsets = <int>[];
      final selected = <MultimediaItem>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: MediaHorizontalList(
                title: 'رائج الآن',
                mediaList: seeded,
                category: ViewAllCategory.providerContent,
                initialViewAllOffset: 30,
                onTap: selected.add,
                loadViewAllPage: (offset) async {
                  offsets.add(offset);
                  return ProviderMediaPage(
                    items: [
                      MultimediaItem(
                        title: 'آخر عمل',
                        url: 'https://animewitcher.com/watch/probe-last',
                        posterUrl: posterUrl,
                      ),
                    ],
                    nextOffset: 31,
                    hasMore: false,
                  );
                },
              ),
            ),
          ),
          GoRoute(
            path: '/view-all',
            builder: (context, state) =>
                ViewAllRoute($extra: state.extra! as ViewAllRouteExtra)
                    .build(context, state),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(MemoryStorageService()),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );

      await tester.pump();
      expect(imageCache.statusForKey(originalKey).tracked, isFalse);
      final before = imageCache.currentSizeBytes;

      await tester.tap(find.text('عرض الكل'));
      await tester.pump();
      final cardFinder = find.byKey(
        const ValueKey<String>('animewitcher:watch:probe-first'),
      );
      final rawFinder = find.descendant(
        of: cardFinder,
        matching: find.byType(RawImage),
      );
      ui.Image? visibleImage() => tester
          .widgetList<RawImage>(rawFinder)
          .map((raw) => raw.image)
          .whereType<ui.Image>()
          .firstOrNull;
      // The new landscape layout can briefly retain the previous portrait
      // frame. Wait for the display-sized landscape decode itself, not just
      // any image while the real async decoder and fade catch up.
      await _waitFor(tester, () {
        if (cardFinder.evaluate().isEmpty ||
            tester.widget<MultimediaCard>(cardFinder).isPortrait) {
          return false;
        }
        final width = artworkDisplayDecodeWidth(
          paintedWidth: MultimediaCardLayout.cardWidth(
            tester.element(cardFinder),
            isPortrait: false,
          ),
          devicePixelRatio: tester.view.devicePixelRatio,
          highQuality: highQualityArtwork.value,
          sizeHighQualityToDisplay: true,
        );
        return visibleImage()?.width == width;
      });
      await tester.pumpAndSettle();
      final drawn = visibleImage()!;
      final bytes = await tester.runAsync(
        () => drawn.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      expect(bytes!.getUint32(0), 0xb36c27ff);
      expect(drawn.width, lessThan(_width));
      expect(drawn.height, lessThan(_height));
      expect(Directionality.of(tester.element(cardFinder)), TextDirection.rtl);
      expect(offsets, isEmpty);
      expect(requests[posterUrl], 1);

      // This is the full-sized key controlled by the probe, not the card's
      // separately sized display frame.
      expect(imageCache.statusForKey(originalKey).tracked, isFalse);
      expect(
        imageCache.currentSizeBytes - before,
        lessThan(_width * _height * 4),
      );

      await tester.tap(cardFinder.hitTestable());
      await tester.pump();
      expect(selected.single, same(first));

      final controller = tester
          .widget<GridView>(find.byType(GridView))
          .controller!;
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(offsets, [30]);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('آخر عمل'), findsWidgets);

      router.pop();
      await tester.pumpAndSettle();
      expect(find.byType(ViewAllScreen), findsNothing);
      expect(find.byType(MediaHorizontalList), findsOneWidget);
      expect(requests[posterUrl], 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
