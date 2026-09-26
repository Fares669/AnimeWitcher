import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Mangayomi reader defaults are preserved', () {
    const settings = MangaReaderSettings();

    expect(settings.defaultMode, MangaReaderMode.vertical);
    expect(settings.animatePageTransitions, isTrue);
    expect(settings.doubleTapAnimationSpeed, 1);
    expect(settings.cropBorders, isFalse);
    expect(settings.scaleType, MangaReaderScaleType.fitScreen);
    expect(settings.pagePreloadAmount, 6);
    expect(settings.background, MangaReaderBackground.black);
    expect(settings.usePageTapZones, isTrue);
    expect(settings.fullScreen, isTrue);
    expect(settings.showPageNumber, isTrue);
    expect(settings.keepScreenOn, isTrue);
    expect(settings.webtoonSidePadding, 0);
    expect(settings.showPageGaps, isTrue);
    expect(settings.webtoonDoubleTapZoomEnabled, isTrue);
    expect(settings.navigateToPan, isTrue);
    expect(settings.doublePageAuto, isFalse);
  });

  test('reader settings JSON round-trips every reader option', () {
    const settings = MangaReaderSettings(
      defaultMode: MangaReaderMode.webtoon,
      animatePageTransitions: false,
      doubleTapAnimationSpeed: 2,
      cropBorders: true,
      scaleType: MangaReaderScaleType.fitWidth,
      pagePreloadAmount: 10,
      background: MangaReaderBackground.grey,
      usePageTapZones: false,
      fullScreen: false,
      showPageNumber: false,
      keepScreenOn: false,
      webtoonSidePadding: 24,
      showPageGaps: false,
      navigationLayout: 3,
      splitWidePages: true,
      dualPageInvert: true,
      dualPageRotateToFit: true,
      dualPageRotateToFitInvert: true,
      doublePageSingleFirstPage: true,
      doublePageAuto: true,
      landscapeZoom: true,
      zoomStartPosition: 2,
      navigateToPan: false,
      tappingInversion: 3,
      flashOnPageChange: true,
      flashDurationMs: 250,
      flashInterval: 4,
      flashColor: 2,
      showNavigationOverlayOnStart: true,
      webtoonDisableZoomOut: true,
      webtoonDoubleTapZoomEnabled: false,
      readerHideThreshold: 2,
      autoScrollSpeed: 25,
    );

    expect(MangaReaderSettings.fromJson(settings.toJson()), settings);
  });

  test('Mangayomi-only reader options are persisted too', () {
    const settings = MangaReaderSettings();

    expect(settings.toJson()['autoReadDuplicateChapters'], isFalse);
    expect(settings.toJson().containsKey('chapterSwipeStartAction'), isTrue);
    expect(settings.toJson().containsKey('chapterSwipeEndAction'), isTrue);
    expect(settings.toJson().containsKey('readerHideThreshold'), isTrue);
    expect(settings.toJson().containsKey('flashColor'), isTrue);
    // Mangayomi's per-page colour settings stay gone; the filter the reader
    // has now is Mihon's, drawn once over the page (see the Mihon features
    // test).
    for (final key in <String>[
      'invertColors',
      'contrast',
      'saturation',
      'enableCustomColorFilter',
      'customColorFilterArgb',
      'colorFilterBlendMode',
    ]) {
      expect(settings.toJson().containsKey(key), isFalse, reason: key);
    }
  });

  test('Mangayomi keeps reader mode, page mode and auto scroll per manga', () {
    final personalized = const MangaReaderSettings()
        .withMangaMode('m1', MangaReaderMode.webtoon)
        .withMangaDoublePage('m1', true)
        .withMangaAutoScroll('m1', enabled: true, speed: 18);

    expect(personalized.modeForManga('m1'), MangaReaderMode.webtoon);
    expect(personalized.modeForManga('m2'), MangaReaderMode.vertical);
    expect(personalized.doublePageForManga('m1'), isTrue);
    expect(personalized.doublePageForManga('m2'), isFalse);
    expect(personalized.autoScrollForManga('m1').enabled, isTrue);
    expect(personalized.autoScrollForManga('m1').speed, 18);
    expect(personalized.autoScrollForManga('m2').enabled, isFalse);

    final restored = MangaReaderSettings.fromJson(personalized.toJson());
    expect(restored.modeForManga('m1'), MangaReaderMode.webtoon);
    expect(restored.doublePageForManga('m1'), isTrue);
    expect(restored.autoScrollForManga('m1').speed, 18);
  });

  test('automatic double page only activates in landscape', () {
    const settings = MangaReaderSettings(doublePageAuto: true);

    expect(
      shouldUseMangaDoublePage(
        settings: settings,
        viewport: const Size(1200, 700),
        mode: MangaReaderMode.pagedRtl,
      ),
      isTrue,
    );
    expect(
      shouldUseMangaDoublePage(
        settings: settings,
        viewport: const Size(700, 1200),
        mode: MangaReaderMode.pagedRtl,
      ),
      isFalse,
    );
    for (final mode in <MangaReaderMode>[
      MangaReaderMode.vertical,
      MangaReaderMode.verticalContinuous,
      MangaReaderMode.webtoon,
    ]) {
      expect(
        shouldUseMangaDoublePage(
          settings: settings,
          viewport: const Size(1200, 700),
          mode: mode,
        ),
        isTrue,
        reason: '${mode.name} supports Mangayomi double-page',
      );
    }
    for (final mode in <MangaReaderMode>[
      MangaReaderMode.horizontalContinuous,
      MangaReaderMode.horizontalContinuousRtl,
    ]) {
      expect(
        shouldUseMangaDoublePage(
          settings: settings,
          viewport: const Size(1200, 700),
          mode: mode,
          forceDoublePage: true,
        ),
        isFalse,
        reason: '${mode.name} is the Mangayomi double-page exception',
      );
    }
  });

  test('Mangayomi double-page spreads preserve logical page order', () {
    expect(
      mangaReaderPageSpreads(
        pageCount: 5,
        singleFirst: true,
      ),
      const <List<int>>[
        <int>[0],
        <int>[1, 2],
        <int>[3, 4],
      ],
    );
    expect(
      mangaReaderPageSpreads(
        pageCount: 4,
        singleFirst: false,
      ),
      const <List<int>>[
        <int>[0, 1],
        <int>[2, 3],
      ],
    );
  });

  test('Mangayomi double-page page labels show the active spread', () {
    expect(
      mangaReaderPageLabel(
        pageIndex: 0,
        pageCount: 5,
        doublePage: true,
        singleFirst: false,
      ),
      '1-2',
    );
    expect(
      mangaReaderPageLabel(
        pageIndex: 1,
        pageCount: 5,
        doublePage: true,
        singleFirst: false,
      ),
      '1-2',
    );
    expect(
      mangaReaderPageLabel(
        pageIndex: 0,
        pageCount: 5,
        doublePage: true,
        singleFirst: true,
      ),
      '1',
    );
    expect(
      mangaReaderPageLabel(
        pageIndex: 2,
        pageCount: 5,
        doublePage: true,
        singleFirst: true,
      ),
      '2-3',
    );
    expect(
      mangaReaderPageLabel(
        pageIndex: 4,
        pageCount: 5,
        doublePage: true,
        singleFirst: false,
      ),
      '5',
    );
  });

  test('Mangayomi reader hide thresholds are preserved', () {
    expect(mangaReaderHideThresholdPixels(0), 5);
    expect(mangaReaderHideThresholdPixels(1), 13);
    expect(mangaReaderHideThresholdPixels(2), 31);
    expect(mangaReaderHideThresholdPixels(3), 47);
  });

  test('Mangayomi double-tap animation speeds are exact', () {
    expect(
      mangaReaderDoubleTapAnimationDuration(0),
      const Duration(milliseconds: 10),
    );
    expect(
      mangaReaderDoubleTapAnimationDuration(1),
      const Duration(milliseconds: 800),
    );
    expect(
      mangaReaderDoubleTapAnimationDuration(2),
      const Duration(milliseconds: 200),
    );
  });

  test('Mangayomi split-wide order respects RTL and dual-page inversion', () {
    const settings = MangaReaderSettings(splitWidePages: true);

    expect(
      mangaReaderWidePageSlices(
        settings: settings,
        isWide: true,
        isRtl: false,
        doublePageActive: false,
      ),
      const <MangaReaderPageSlice>[
        MangaReaderPageSlice.left,
        MangaReaderPageSlice.right,
      ],
    );
    expect(
      mangaReaderWidePageSlices(
        settings: settings,
        isWide: true,
        isRtl: true,
        doublePageActive: false,
      ),
      const <MangaReaderPageSlice>[
        MangaReaderPageSlice.right,
        MangaReaderPageSlice.left,
      ],
    );
    expect(
      mangaReaderWidePageSlices(
        settings: settings.copyWith(dualPageInvert: true),
        isWide: true,
        isRtl: true,
        doublePageActive: false,
      ),
      const <MangaReaderPageSlice>[
        MangaReaderPageSlice.left,
        MangaReaderPageSlice.right,
      ],
    );
    expect(
      mangaReaderWidePageSlices(
        settings: settings,
        isWide: true,
        isRtl: false,
        doublePageActive: true,
      ),
      const <MangaReaderPageSlice>[MangaReaderPageSlice.full],
    );
  });

  test('Mangayomi rotate-to-fit only rotates landscape pages', () {
    const normal = MangaReaderSettings(dualPageRotateToFit: true);
    const inverted = MangaReaderSettings(
      dualPageRotateToFit: true,
      dualPageRotateToFitInvert: true,
    );

    expect(
      mangaReaderRotateQuarterTurns(
        settings: normal,
        imageSize: const Size(1600, 900),
      ),
      1,
    );
    expect(
      mangaReaderRotateQuarterTurns(
        settings: inverted,
        imageSize: const Size(1600, 900),
      ),
      3,
    );
    expect(
      mangaReaderRotateQuarterTurns(
        settings: normal,
        imageSize: const Size(900, 1600),
      ),
      0,
    );
  });

  test('Mangayomi landscape zoom respects start position', () {
    const left = MangaReaderSettings(
      landscapeZoom: true,
      zoomStartPosition: 0,
    );
    const right = MangaReaderSettings(
      landscapeZoom: true,
      zoomStartPosition: 1,
    );
    const center = MangaReaderSettings(
      landscapeZoom: true,
      zoomStartPosition: 2,
    );
    const image = Size(1600, 900);
    const viewport = Size(900, 1200);

    final leftTarget = mangaReaderLandscapeZoomTarget(
      settings: left,
      imageSize: image,
      viewport: viewport,
    );
    final rightTarget = mangaReaderLandscapeZoomTarget(
      settings: right,
      imageSize: image,
      viewport: viewport,
    );
    final centerTarget = mangaReaderLandscapeZoomTarget(
      settings: center,
      imageSize: image,
      viewport: viewport,
    );

    expect(leftTarget, isNotNull);
    expect(leftTarget!.scale, greaterThan(1));
    expect(leftTarget.focalPoint.dx, 0);
    expect(rightTarget!.focalPoint.dx, viewport.width);
    expect(centerTarget!.focalPoint, viewport.center(Offset.zero));
  });


}
