import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_keyboard_handler.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/subsampling/manga_min_subsampling_image.dart';
import 'package:animewitcher/features/manga/reader/subsampling/src/tiling_engine.dart';
import 'package:animewitcher/features/manga/reader/subsampling/subsampling_scale_image_view.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_filter_layer.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_settings_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

KeyDownEvent _down(LogicalKeyboardKey key, PhysicalKeyboardKey physical) =>
    KeyDownEvent(
      physicalKey: physical,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

void main() {
  group('settings', () {
    test('the filter, turning and volume keys survive a save', () {
      final saved = const MangaReaderSettings(
        customBrightness: true,
        brightness: -40,
        colorFilter: true,
        colorFilterValue: 0x801E88E5,
        colorFilterMode: MangaReaderColorBlend.multiply,
        grayscale: true,
        invertedColors: true,
        readWithVolumeKeys: true,
        readWithVolumeKeysInverted: true,
        showReadingMode: false,
      ).withMangaOrientation('m1', MangaReaderOrientation.landscape);

      final loaded = MangaReaderSettings.fromJson(saved.toJson());

      expect(loaded, saved);
      expect(
        loaded.orientationForManga('m1'),
        MangaReaderOrientation.landscape,
      );
      expect(loaded.orientationForManga('other'), MangaReaderOrientation.free);
    });

    test('older saves read with the new options off', () {
      final loaded = MangaReaderSettings.fromJson(const <String, dynamic>{});
      expect(loaded.customBrightness, isFalse);
      expect(loaded.colorFilter, isFalse);
      expect(loaded.readWithVolumeKeys, isFalse);
      expect(loaded.showReadingMode, isTrue);
    });

    test('dimming stays within Mihon\'s range', () {
      final loaded = MangaReaderSettings.fromJson(const <String, dynamic>{
        'customBrightness': true,
        'brightness': -500,
      });
      expect(loaded.brightness, -75);
      expect(mangaReaderDimAlpha(loaded), closeTo(0.75, 0.001));
      expect(mangaReaderDimAlpha(loaded.copyWith(customBrightness: false)), 0);
    });

    test('the old side bar switch carries over to every mode', () {
      final kept = MangaReaderSettings.fromJson(const <String, dynamic>{
        'verticalPageBar': true,
      });
      for (final mode in MangaReaderMode.values) {
        expect(kept.usesVerticalBar(mode), isTrue, reason: mode.name);
      }
      final saved = const MangaReaderSettings(
        verticalBarModes: <MangaReaderMode>{MangaReaderMode.webtoon},
        verticalBarLeft: true,
        verticalBarHeight: 65,
        showActionsOnLongTap: false,
      ).withMangaMode('m1', MangaReaderMode.pagedRtl);
      final loaded = MangaReaderSettings.fromJson(saved.toJson());
      expect(loaded, saved);
      expect(loaded.hasOwnMode('m1'), isTrue);
      expect(loaded.withoutMangaMode('m1').hasOwnMode('m1'), isFalse);
    });

    test('free turning leaves the device to decide', () {
      expect(mangaReaderOrientations(MangaReaderOrientation.free), isEmpty);
      // Mihon's portrait is either way up; locked portrait only one.
      expect(
        mangaReaderOrientations(MangaReaderOrientation.portrait),
        <DeviceOrientation>[
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ],
      );
      expect(
        mangaReaderOrientations(MangaReaderOrientation.lockedPortrait),
        <DeviceOrientation>[DeviceOrientation.portraitUp],
      );
      expect(
        mangaReaderOrientations(MangaReaderOrientation.reversePortrait),
        <DeviceOrientation>[DeviceOrientation.portraitDown],
      );
    });
  });

  group('volume keys', () {
    var next = 0;
    var previous = 0;
    final handler = MangaReaderKeyboardHandler(
      onNextPage: () => next++,
      onPreviousPage: () => previous++,
    );
    final down = _down(
      LogicalKeyboardKey.audioVolumeDown,
      PhysicalKeyboardKey.audioVolumeDown,
    );
    final up = _down(
      LogicalKeyboardKey.audioVolumeUp,
      PhysicalKeyboardKey.audioVolumeUp,
    );

    setUp(() {
      next = 0;
      previous = 0;
    });

    test('left to the system unless switched on', () {
      expect(handler.handleKeyEvent(down), isFalse);
      expect(next, 0);
    });

    test('down is the next page, up the one before', () {
      expect(handler.handleKeyEvent(down, volumeKeys: true), isTrue);
      expect(handler.handleKeyEvent(up, volumeKeys: true), isTrue);
      expect(next, 1);
      expect(previous, 1);
    });

    test('inverted, down goes back', () {
      handler.handleKeyEvent(down, volumeKeys: true, volumeKeysInverted: true);
      expect(previous, 1);
      expect(next, 0);
    });

    test('releasing the key is kept from the system too', () {
      const release = KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.audioVolumeDown,
        logicalKey: LogicalKeyboardKey.audioVolumeDown,
        timeStamp: Duration.zero,
      );
      expect(handler.handleKeyEvent(release, volumeKeys: true), isTrue);
      expect(next, 0);
    });
  });

  group('filter layer', () {
    Future<void> pump(WidgetTester tester, MangaReaderSettings settings) =>
        tester.pumpWidget(
          MaterialApp(
            home: MangaReaderFilterLayer(
              settings: settings,
              child: const SizedBox.expand(),
            ),
          ),
        );

    testWidgets('nothing is drawn over the page by default', (tester) async {
      await pump(tester, const MangaReaderSettings());
      expect(find.byType(ColorFiltered), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('manga-reader-dim')),
        findsNothing,
      );
    });

    testWidgets('each filter is drawn when it is on', (tester) async {
      await pump(
        tester,
        const MangaReaderSettings(
          customBrightness: true,
          brightness: -30,
          colorFilter: true,
          grayscale: true,
          invertedColors: true,
        ),
      );
      expect(find.byType(ColorFiltered), findsNWidgets(3));
      expect(
        find.byKey(const ValueKey<String>('manga-reader-color-filter')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('manga-reader-dim')),
        findsOneWidget,
      );
    });
  });

  group('panel', () {
    Future<MangaReaderSettings Function()> pump(
      WidgetTester tester, {
      MangaReaderPanelTab tab = MangaReaderPanelTab.filter,
      ValueChanged<MangaReaderOrientation?>? onOrientation,
      bool showVolumeKeys = false,
    }) async {
      // Tall enough for a whole tab of the sheet.
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var settings = const MangaReaderSettings();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => MangaReaderSettingsPanel(
                  settings: settings,
                  mode: MangaReaderMode.pagedLtr,
                  doublePage: false,
                  initialTab: tab,
                  onOrientation: onOrientation,
                  showVolumeKeys: showVolumeKeys,
                  onMode: (_) {},
                  onDoublePage: (_) {},
                  onUpdate: (change) =>
                      setState(() => settings = change(settings)),
                  onOpenAllSettings: () {},
                ),
              ),
            ),
          ),
        ),
      );
      return () => settings;
    }

    testWidgets('the filter tab turns on dimming and a tint', (tester) async {
      final settings = await pump(tester);

      await tester.tap(
        find.byKey(
          const ValueKey<String>('manga-reader-switch-custom-brightness'),
        ),
      );
      await tester.pumpAndSettle();
      expect(settings().customBrightness, isTrue);
      expect(
        find.byKey(const ValueKey<String>('manga-reader-slider-brightness')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-switch-color-filter')),
      );
      await tester.pumpAndSettle();
      // Mihon's red, green, blue and alpha sliders.
      tester
          .widget<Slider>(
            find.byKey(const ValueKey<String>('manga-reader-slider-tint-b')),
          )
          .onChanged!(200);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-blend-multiply')),
      );
      await tester.pumpAndSettle();
      expect(settings().colorFilter, isTrue);
      expect(settings().colorFilterValue & 0xFF, 200);
      // The rest of the default tint is untouched.
      expect(settings().colorFilterValue >> 24, 0x40);
      expect(settings().colorFilterMode, MangaReaderColorBlend.multiply);

      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-switch-grayscale')),
      );
      await tester.pumpAndSettle();
      expect(settings().grayscale, isTrue);
    });

    testWidgets('turning and volume keys only where the device has them', (
      tester,
    ) async {
      await pump(tester, tab: MangaReaderPanelTab.mode);
      expect(
        find.byKey(const ValueKey<String>('manga-reader-orientation-portrait')),
        findsNothing,
      );
      await pump(tester, tab: MangaReaderPanelTab.general);
      expect(
        find.byKey(const ValueKey<String>('manga-reader-switch-volume-keys')),
        findsNothing,
      );

      // Rotation sits with the reading mode, as in Mihon.
      MangaReaderOrientation? picked;
      await pump(
        tester,
        tab: MangaReaderPanelTab.mode,
        onOrientation: (value) => picked = value,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-orientation-portrait')),
      );
      expect(picked, MangaReaderOrientation.portrait);

      final settings = await pump(
        tester,
        tab: MangaReaderPanelTab.general,
        showVolumeKeys: true,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-switch-volume-keys')),
      );
      await tester.pumpAndSettle();
      expect(settings().readWithVolumeKeys, isTrue);
      expect(
        find.byKey(
          const ValueKey<String>('manga-reader-switch-volume-keys-inverted'),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('a strip is always as wide as the screen, whatever the scale', (
    tester,
  ) async {
    // Original size in a strip left a narrow page floating in a band sized
    // for a full-width one, with thousands of pixels of black above it.
    final dir = Directory.systemTemp.createTempSync('aw_strip_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/page.jpg')..writeAsBytesSync(<int>[0]);
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          child: MangaPageImage(
            page: MangaPage(index: 0, imageUrl: file.uri.toString()),
            settings: const MangaReaderSettings(
              scaleType: MangaReaderScaleType.originalSize,
            ),
          ),
        ),
      ),
    );
    final strip = tester.widget<MangaMinSubsamplingImage>(
      find.byType(MangaMinSubsamplingImage),
    );
    expect(strip.minimumScaleType, ScaleType.fitWidth);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('a tall page is decoded in pieces no taller than a tile', () {
    // One piece for a whole 800 by 15,000 webtoon page was a texture taller
    // than a graphics card takes.
    final engine = TilingEngine()
      ..initialiseTileMap(
        sWidth: 800,
        sHeight: 15000,
        maxTileWidth: 4096,
        maxTileHeight: 4096,
        baseSampleSize: 1,
        viewWidth: 1330,
        viewHeight: 900,
      );
    final tiles = engine.tileMap[1]!;
    expect(tiles, hasLength(4));
    for (final tile in tiles) {
      expect(tile.sRect.height, lessThanOrEqualTo(4096));
    }
    expect(tiles.last.sRect.bottom, 15000);
    engine.dispose();
  });
}
