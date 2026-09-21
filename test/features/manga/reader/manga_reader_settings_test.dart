import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Mangayomi reader defaults are preserved', () {
    const settings = MangaReaderSettings();

    expect(settings.defaultMode, MangaReaderMode.pagedRtl);
    expect(settings.animatePageTransitions, isTrue);
    expect(settings.doubleTapAnimationSpeed, 1);
    expect(settings.cropBorders, isFalse);
    expect(settings.scaleType, MangaReaderScaleType.fitScreen);
    expect(settings.pagePreloadAmount, 6);
    expect(settings.background, MangaReaderBackground.automatic);
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
      invertColors: true,
      grayscale: true,
      brightness: 0.15,
      contrast: 1.25,
      saturation: 0.8,
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
      autoScrollSpeed: 35,
    );

    expect(MangaReaderSettings.fromJson(settings.toJson()), settings);
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
    expect(
      shouldUseMangaDoublePage(
        settings: settings,
        viewport: const Size(1200, 700),
        mode: MangaReaderMode.webtoon,
      ),
      isFalse,
    );
  });

  test('reader color matrix changes when filters are enabled', () {
    const settings = MangaReaderSettings(
      invertColors: true,
      grayscale: true,
      brightness: 0.1,
      contrast: 1.2,
      saturation: 0.7,
    );

    expect(mangaReaderColorMatrix(settings), hasLength(20));
    expect(mangaReaderColorMatrix(settings), isNot(equals(identityMangaReaderColorMatrix)));
  });
}
