import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/animewitcher_character_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/characters/presentation/anime_characters_screen.dart';
import 'package:animewitcher/features/characters/presentation/character_card.dart';
import 'package:animewitcher/features/characters/presentation/character_details_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/thumbnail_error_placeholder.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _CachePaths extends PathProviderPlatform {
  _CachePaths(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

class _CastProvider extends AnimeWitcherNativeProvider {
  _CastProvider(this.cast) : super(Dio(), SettingsRepository(StorageService()));

  final List<Actor> cast;

  @override
  Future<List<Actor>> getAnimeCharacters(
    String animeId, {
    int limit = 50,
    String? role,
  }) async => cast;

  @override
  Future<AnimeWitcherCharacterDocument?> getCharacterDocument(String id) async {
    final actor = cast.firstWhere((actor) => actor.id == id);
    return AnimeWitcherCharacterDocument(
      id: id,
      name: actor.name,
      likes: actor.likes,
      imageUrl: actor.image,
    );
  }

  @override
  Future<List<AnimeWitcherCharacterShow>> getCharacterAnimes(
    AnimeWitcherCharacterDocument character,
  ) async => const [];
}

const _boundary = ValueKey<String>('casting-portrait-screen');
const _top = 0x9867baff;
const _bottom = 0x47a76bff;

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawColor(const Color(_top >> 8 | 0xff000000), ui.BlendMode.src)
    ..drawRect(
      Rect.fromLTRB(0, height / 2, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(_bottom >> 8 | 0xff000000),
    );
  final picture = recorder.endRecording();
  final frame = await picture.toImage(width, height);
  picture.dispose();
  try {
    final data = (await frame.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    frame.dispose();
  }
}

Finder get _photos => find.byWidgetPredicate(
  (widget) => widget is RawImage && widget.image != null,
);

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var count = 0; count < 160 && !ready(); count++) {
    await tester.pump(const Duration(milliseconds: 40));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(ready(), isTrue);
  await tester.pumpAndSettle();
}

Future<(int, int)> _paintedColors(WidgetTester tester, Finder photo) async {
  final rect = tester.getRect(photo);
  final render = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  return (await tester.runAsync(() async {
    final screenshot = await render.toImage(pixelRatio: 2);
    try {
      final rgba = (await screenshot.toByteData())!;
      final x = (rect.center.dx * 2).round();
      int at(double relative) {
        final y = ((rect.top + rect.height * relative) * 2).round();
        return rgba.getUint32((y * screenshot.width + x) * 4);
      }

      return (at(0.28), at(0.65));
    } finally {
      screenshot.dispose();
    }
  }))!;
}

void main() {
  late Directory temp;
  late DefaultCacheManager manager;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('aw-character-cache-');
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _CachePaths(temp.path);
    try {
      manager = DefaultCacheManager();
      await manager.getFileFromCache('aw-character-cache-setup');
    } finally {
      PathProviderPlatform.instance = paths;
    }
  });
  tearDownAll(() => temp.delete(recursive: true));

  const viewports = [
    (
      label: 'phone',
      platform: TargetPlatform.android,
      physicalSize: Size(780, 1688),
      decode: (448, 672),
    ),
    (
      label: 'desktop',
      platform: TargetPlatform.linux,
      physicalSize: Size(2560, 1440),
      decode: (598, 896),
    ),
  ];
  for (final viewport in viewports) {
    testWidgets(
      'cast grid and real details hero share a bounded native decode on ${viewport.label}',
      (tester) async {
        final originalMode = highQualityArtwork.value;
        highQualityArtwork.value = true;
        tester.view.physicalSize = viewport.physicalSize;
        tester.view.devicePixelRatio = 2;
        final cache = PaintingBinding.instance.imageCache;
        void clear() => cache
          ..clear()
          ..clearLiveImages();
        clear();
        addTearDown(() {
          tester.view.reset();
          highQualityArtwork.value = originalMode;
          clear();
        });

        const dimension = (1200, 1800);
        final actors = [
          for (var i = 0; i < 12; i++)
            Actor(
              id: '$i',
              name: 'Person-$i',
              image:
                  'https://character.fixture.invalid/large-${viewport.label}-$i.png',
              likes: 5,
            ),
        ];
        await tester.runAsync(() async {
          final data = await _png(dimension.$1, dimension.$2);
          for (final actor in actors) {
            await manager.putFile(actor.image!, data, fileExtension: 'png');
          }
        });

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              storageServiceProvider.overrideWithValue(StorageService()),
              activeProviderProvider.overrideWithValue(_CastProvider(actors)),
            ],
            child: const RepaintBoundary(
              key: _boundary,
              child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: AnimeCharactersScreen(animeId: 'fixture'),
              ),
            ),
          ),
        );
        await _waitFor(
          tester,
          () => _photos.evaluate().length == actors.length,
        );

        final card = find.widgetWithText(CharacterPosterCard, 'Person-0');
        final cardPhoto = find.descendant(of: card, matching: _photos);
        final cardSize = tester.widget<RawImage>(cardPhoto).image!;
        final gridBytes = cache.currentSizeBytes;
        final gridCount = cache.currentSize;
        debugPrint(
          'Cast grid: ${cardSize.width}x${cardSize.height}, '
          'cache=$gridBytes bytes, entries=$gridCount',
        );
        expect(await _paintedColors(tester, cardPhoto), (_top, _bottom));
        expect(find.text('5'), findsNWidgets(actors.length));
        await tester.tap(card);
        await _waitFor(
          tester,
          () => find
              .descendant(
                of: find.byType(CharacterDetailsScreen),
                matching: _photos,
              )
              .evaluate()
              .isNotEmpty,
        );

        final heroPhoto = find.descendant(
          of: find.byType(CharacterDetailsScreen),
          matching: _photos,
        );
        expect(tester.getSize(heroPhoto), const Size(168, 236));
        expect(await _paintedColors(tester, heroPhoto), (_top, _bottom));
        final heroSize = tester.widget<RawImage>(heroPhoto).image!;
        final fullKey = CachedNetworkImageProvider(actors.first.image!);
        debugPrint(
          'Character details: ${heroSize.width}x${heroSize.height}, '
          'cache=${cache.currentSizeBytes} bytes, entries=${cache.currentSize}',
        );
        expect(cache.currentSizeBytes, gridBytes);
        expect(cache.currentSize, gridCount);
        expect(gridCount, actors.length);

        expect((cardSize.width, cardSize.height), viewport.decode);
        expect((heroSize.width, heroSize.height), viewport.decode);
        expect(cache.statusForKey(fullKey).tracked, isFalse);
        expect(
          gridBytes,
          actors.length * viewport.decode.$1 * viewport.decode.$2 * 4,
        );

        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        navigator.pop();
        await tester.pumpAndSettle();
        expect(card, findsOneWidget);
        expect(cache.currentSizeBytes, gridBytes);
      },
      variant: TargetPlatformVariant.only(viewport.platform),
    );
  }

  testWidgets(
    'retains cover for a landscape source and original Standard key',
    (tester) async {
      final originalMode = highQualityArtwork.value;
      highQualityArtwork.value = true;
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2;
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      addTearDown(() {
        tester.view.reset();
        highQualityArtwork.value = originalMode;
        cache
          ..clear()
          ..clearLiveImages();
      });

      const url = 'https://character.fixture.invalid/landscape.png';
      await tester.runAsync(() async {
        await manager.putFile(url, await _png(1800, 900), fileExtension: 'png');
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: _boundary,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 110,
                  height: 198,
                  child: CharacterPosterCard(
                    character: const AnimeWitcherCharacterHit(
                      id: 'landscape',
                      name: 'Landscape',
                      imageUrl: url,
                    ),
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _waitFor(tester, () => _photos.evaluate().isNotEmpty);
      final high = tester.widget<RawImage>(_photos).image!;
      expect((high.width, high.height), (1280, 640));
      expect(await _paintedColors(tester, _photos), (_top, _bottom));

      highQualityArtwork.value = false;
      await _waitFor(
        tester,
        () => _photos
            .evaluate()
            .map((element) => (element.widget as RawImage).image!.width)
            .contains(320),
      );
      const nativeProvider = CachedNetworkImageProvider(url);
      final standardKey = await ResizeImage(
        nativeProvider,
        width: 320,
      ).obtainKey(ImageConfiguration.empty);
      expect(cache.statusForKey(standardKey).tracked, isTrue);
      expect(await _paintedColors(tester, _photos), (_top, _bottom));
    },
  );

  testWidgets('bad and missing art keep the labelled fallback', (tester) async {
    const corruptedUrl = 'https://character.fixture.invalid/corrupt.png';
    await tester.runAsync(() async {
      await manager.putFile(
        corruptedUrl,
        Uint8List.fromList([0, 1, 2, 3]),
        fileExtension: 'png',
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              for (final (id, image) in [
                ('invalid', corruptedUrl),
                ('missing', ''),
              ])
                SizedBox(
                  width: 110,
                  height: 198,
                  child: CharacterPosterCard(
                    character: AnimeWitcherCharacterHit(
                      id: id,
                      name: id,
                      imageUrl: image,
                    ),
                    onTap: () {},
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await _waitFor(
      tester,
      () => find.byType(ThumbnailErrorPlaceholder).evaluate().length == 2,
    );
    expect(_photos, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
