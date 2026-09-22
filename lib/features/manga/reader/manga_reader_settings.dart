// Adapted from the Mangayomi reader preference surface.
// Mangayomi is licensed under Apache-2.0. See docs/third_party/MANGAYOMI_READER_NOTICE.md.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

enum MangaReaderMode {
  vertical,
  pagedLtr,
  pagedRtl,
  verticalContinuous,
  webtoon,
  horizontalContinuous,
  horizontalContinuousRtl,
}

extension MangaReaderModeX on MangaReaderMode {
  bool get isContinuous =>
      this == MangaReaderMode.verticalContinuous ||
      this == MangaReaderMode.webtoon ||
      this == MangaReaderMode.horizontalContinuous ||
      this == MangaReaderMode.horizontalContinuousRtl;

  bool get isVertical =>
      this == MangaReaderMode.vertical ||
      this == MangaReaderMode.verticalContinuous ||
      this == MangaReaderMode.webtoon;

  bool get isRtl =>
      this == MangaReaderMode.pagedRtl ||
      this == MangaReaderMode.horizontalContinuousRtl;
}

enum MangaReaderScaleType {
  fitScreen,
  stretch,
  fitWidth,
  fitHeight,
  originalSize,
  smartFit,
}

enum MangaReaderBackground { black, grey, white, automatic }

enum MangaReaderColorBlendMode {
  none,
  multiply,
  screen,
  overlay,
  colorDodge,
  lighten,
  colorBurn,
  darken,
  difference,
  saturation,
  softLight,
  plus,
  exclusion,
}

enum MangaReaderChapterSwipeAction {
  toggleBookmark,
  toggleRead,
  download,
  disabled,
}

enum MangaReaderPageSlice { full, left, right }

@immutable
class MangaReaderSettings {
  const MangaReaderSettings({
    this.defaultMode = MangaReaderMode.vertical,
    this.animatePageTransitions = true,
    this.doubleTapAnimationSpeed = 1,
    this.cropBorders = false,
    this.scaleType = MangaReaderScaleType.fitScreen,
    this.pagePreloadAmount = 6,
    this.background = MangaReaderBackground.black,
    this.usePageTapZones = true,
    this.fullScreen = true,
    this.showPageNumber = true,
    this.keepScreenOn = true,
    this.webtoonSidePadding = 0,
    this.showPageGaps = true,
    this.autoReadDuplicateChapters = false,
    this.invertColors = false,
    this.grayscale = false,
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.enableCustomColorFilter = false,
    this.customColorFilterArgb = 0x00000000,
    this.colorFilterBlendMode = MangaReaderColorBlendMode.none,
    this.navigationLayout = 0,
    this.splitWidePages = false,
    this.dualPageInvert = false,
    this.dualPageRotateToFit = false,
    this.dualPageRotateToFitInvert = false,
    this.doublePageSingleFirstPage = false,
    this.doublePageAuto = false,
    this.landscapeZoom = false,
    this.zoomStartPosition = 1,
    this.navigateToPan = true,
    this.tappingInversion = 0,
    this.flashOnPageChange = false,
    this.flashDurationMs = 100,
    this.flashInterval = 1,
    this.flashColor = 0,
    this.showNavigationOverlayOnStart = false,
    this.webtoonDisableZoomOut = false,
    this.webtoonDoubleTapZoomEnabled = true,
    this.readerHideThreshold = 1,
    this.autoScrollEnabled = false,
    this.autoScrollSpeed = 10,
    this.chapterSwipeStartAction =
        MangaReaderChapterSwipeAction.toggleBookmark,
    this.chapterSwipeEndAction = MangaReaderChapterSwipeAction.toggleRead,
    this.personalReaderModes = const <String, MangaReaderMode>{},
    this.personalDoublePage = const <String, bool>{},
    this.personalAutoScrollEnabled = const <String, bool>{},
    this.personalAutoScrollSpeed = const <String, double>{},
  });

  final MangaReaderMode defaultMode;
  final bool animatePageTransitions;
  final int doubleTapAnimationSpeed;
  final bool cropBorders;
  final MangaReaderScaleType scaleType;
  final int pagePreloadAmount;
  final MangaReaderBackground background;
  final bool usePageTapZones;
  final bool fullScreen;
  final bool showPageNumber;
  final bool keepScreenOn;
  final int webtoonSidePadding;
  final bool showPageGaps;
  final bool autoReadDuplicateChapters;
  final bool invertColors;
  final bool grayscale;
  final double brightness;
  final double contrast;
  final double saturation;
  final bool enableCustomColorFilter;
  final int customColorFilterArgb;
  final MangaReaderColorBlendMode colorFilterBlendMode;
  final int navigationLayout;
  final bool splitWidePages;
  final bool dualPageInvert;
  final bool dualPageRotateToFit;
  final bool dualPageRotateToFitInvert;
  final bool doublePageSingleFirstPage;
  final bool doublePageAuto;
  final bool landscapeZoom;
  final int zoomStartPosition;
  final bool navigateToPan;
  final int tappingInversion;
  final bool flashOnPageChange;
  final int flashDurationMs;
  final int flashInterval;
  final int flashColor;
  final bool showNavigationOverlayOnStart;
  final bool webtoonDisableZoomOut;
  final bool webtoonDoubleTapZoomEnabled;
  final int readerHideThreshold;
  final bool autoScrollEnabled;
  final double autoScrollSpeed;
  final MangaReaderChapterSwipeAction chapterSwipeStartAction;
  final MangaReaderChapterSwipeAction chapterSwipeEndAction;
  final Map<String, MangaReaderMode> personalReaderModes;
  final Map<String, bool> personalDoublePage;
  final Map<String, bool> personalAutoScrollEnabled;
  final Map<String, double> personalAutoScrollSpeed;

  MangaReaderMode modeForManga(String mangaId) =>
      personalReaderModes[mangaId.trim()] ?? defaultMode;

  bool doublePageForManga(String mangaId) =>
      personalDoublePage[mangaId.trim()] ?? false;

  ({bool enabled, double speed}) autoScrollForManga(String mangaId) {
    final id = mangaId.trim();
    return (
      enabled: personalAutoScrollEnabled[id] ?? false,
      speed: personalAutoScrollSpeed[id] ?? 10,
    );
  }

  MangaReaderSettings withMangaMode(String mangaId, MangaReaderMode mode) {
    final id = mangaId.trim();
    if (id.isEmpty) return this;
    return copyWith(
      personalReaderModes: <String, MangaReaderMode>{
        ...personalReaderModes,
        id: mode,
      },
    );
  }

  MangaReaderSettings withMangaDoublePage(String mangaId, bool enabled) {
    final id = mangaId.trim();
    if (id.isEmpty) return this;
    return copyWith(
      personalDoublePage: <String, bool>{
        ...personalDoublePage,
        id: enabled,
      },
    );
  }

  MangaReaderSettings withMangaAutoScroll(
    String mangaId, {
    required bool enabled,
    required double speed,
  }) {
    final id = mangaId.trim();
    if (id.isEmpty) return this;
    return copyWith(
      personalAutoScrollEnabled: <String, bool>{
        ...personalAutoScrollEnabled,
        id: enabled,
      },
      personalAutoScrollSpeed: <String, double>{
        ...personalAutoScrollSpeed,
        id: speed.clamp(2, 30).toDouble(),
      },
    );
  }

  MangaReaderSettings copyWith({
    MangaReaderMode? defaultMode,
    bool? animatePageTransitions,
    int? doubleTapAnimationSpeed,
    bool? cropBorders,
    MangaReaderScaleType? scaleType,
    int? pagePreloadAmount,
    MangaReaderBackground? background,
    bool? usePageTapZones,
    bool? fullScreen,
    bool? showPageNumber,
    bool? keepScreenOn,
    int? webtoonSidePadding,
    bool? showPageGaps,
    bool? autoReadDuplicateChapters,
    bool? invertColors,
    bool? grayscale,
    double? brightness,
    double? contrast,
    double? saturation,
    bool? enableCustomColorFilter,
    int? customColorFilterArgb,
    MangaReaderColorBlendMode? colorFilterBlendMode,
    int? navigationLayout,
    bool? splitWidePages,
    bool? dualPageInvert,
    bool? dualPageRotateToFit,
    bool? dualPageRotateToFitInvert,
    bool? doublePageSingleFirstPage,
    bool? doublePageAuto,
    bool? landscapeZoom,
    int? zoomStartPosition,
    bool? navigateToPan,
    int? tappingInversion,
    bool? flashOnPageChange,
    int? flashDurationMs,
    int? flashInterval,
    int? flashColor,
    bool? showNavigationOverlayOnStart,
    bool? webtoonDisableZoomOut,
    bool? webtoonDoubleTapZoomEnabled,
    int? readerHideThreshold,
    bool? autoScrollEnabled,
    double? autoScrollSpeed,
    MangaReaderChapterSwipeAction? chapterSwipeStartAction,
    MangaReaderChapterSwipeAction? chapterSwipeEndAction,
    Map<String, MangaReaderMode>? personalReaderModes,
    Map<String, bool>? personalDoublePage,
    Map<String, bool>? personalAutoScrollEnabled,
    Map<String, double>? personalAutoScrollSpeed,
  }) {
    return MangaReaderSettings(
      defaultMode: defaultMode ?? this.defaultMode,
      animatePageTransitions:
          animatePageTransitions ?? this.animatePageTransitions,
      doubleTapAnimationSpeed:
          doubleTapAnimationSpeed ?? this.doubleTapAnimationSpeed,
      cropBorders: cropBorders ?? this.cropBorders,
      scaleType: scaleType ?? this.scaleType,
      pagePreloadAmount: pagePreloadAmount ?? this.pagePreloadAmount,
      background: background ?? this.background,
      usePageTapZones: usePageTapZones ?? this.usePageTapZones,
      fullScreen: fullScreen ?? this.fullScreen,
      showPageNumber: showPageNumber ?? this.showPageNumber,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      webtoonSidePadding: webtoonSidePadding ?? this.webtoonSidePadding,
      showPageGaps: showPageGaps ?? this.showPageGaps,
      autoReadDuplicateChapters:
          autoReadDuplicateChapters ?? this.autoReadDuplicateChapters,
      invertColors: invertColors ?? this.invertColors,
      grayscale: grayscale ?? this.grayscale,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      enableCustomColorFilter:
          enableCustomColorFilter ?? this.enableCustomColorFilter,
      customColorFilterArgb:
          customColorFilterArgb ?? this.customColorFilterArgb,
      colorFilterBlendMode:
          colorFilterBlendMode ?? this.colorFilterBlendMode,
      navigationLayout: navigationLayout ?? this.navigationLayout,
      splitWidePages: splitWidePages ?? this.splitWidePages,
      dualPageInvert: dualPageInvert ?? this.dualPageInvert,
      dualPageRotateToFit: dualPageRotateToFit ?? this.dualPageRotateToFit,
      dualPageRotateToFitInvert:
          dualPageRotateToFitInvert ?? this.dualPageRotateToFitInvert,
      doublePageSingleFirstPage:
          doublePageSingleFirstPage ?? this.doublePageSingleFirstPage,
      doublePageAuto: doublePageAuto ?? this.doublePageAuto,
      landscapeZoom: landscapeZoom ?? this.landscapeZoom,
      zoomStartPosition: zoomStartPosition ?? this.zoomStartPosition,
      navigateToPan: navigateToPan ?? this.navigateToPan,
      tappingInversion: tappingInversion ?? this.tappingInversion,
      flashOnPageChange: flashOnPageChange ?? this.flashOnPageChange,
      flashDurationMs: flashDurationMs ?? this.flashDurationMs,
      flashInterval: flashInterval ?? this.flashInterval,
      flashColor: flashColor ?? this.flashColor,
      showNavigationOverlayOnStart:
          showNavigationOverlayOnStart ?? this.showNavigationOverlayOnStart,
      webtoonDisableZoomOut:
          webtoonDisableZoomOut ?? this.webtoonDisableZoomOut,
      webtoonDoubleTapZoomEnabled:
          webtoonDoubleTapZoomEnabled ?? this.webtoonDoubleTapZoomEnabled,
      readerHideThreshold: readerHideThreshold ?? this.readerHideThreshold,
      autoScrollEnabled: autoScrollEnabled ?? this.autoScrollEnabled,
      autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
      chapterSwipeStartAction:
          chapterSwipeStartAction ?? this.chapterSwipeStartAction,
      chapterSwipeEndAction:
          chapterSwipeEndAction ?? this.chapterSwipeEndAction,
      personalReaderModes: personalReaderModes ?? this.personalReaderModes,
      personalDoublePage: personalDoublePage ?? this.personalDoublePage,
      personalAutoScrollEnabled:
          personalAutoScrollEnabled ?? this.personalAutoScrollEnabled,
      personalAutoScrollSpeed:
          personalAutoScrollSpeed ?? this.personalAutoScrollSpeed,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'defaultMode': defaultMode.name,
    'animatePageTransitions': animatePageTransitions,
    'doubleTapAnimationSpeed': doubleTapAnimationSpeed,
    'cropBorders': cropBorders,
    'scaleType': scaleType.name,
    'pagePreloadAmount': pagePreloadAmount,
    'background': background.name,
    'usePageTapZones': usePageTapZones,
    'fullScreen': fullScreen,
    'showPageNumber': showPageNumber,
    'keepScreenOn': keepScreenOn,
    'webtoonSidePadding': webtoonSidePadding,
    'showPageGaps': showPageGaps,
    'autoReadDuplicateChapters': autoReadDuplicateChapters,
    'invertColors': invertColors,
    'grayscale': grayscale,
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
    'enableCustomColorFilter': enableCustomColorFilter,
    'customColorFilterArgb': customColorFilterArgb,
    'colorFilterBlendMode': colorFilterBlendMode.name,
    'navigationLayout': navigationLayout,
    'splitWidePages': splitWidePages,
    'dualPageInvert': dualPageInvert,
    'dualPageRotateToFit': dualPageRotateToFit,
    'dualPageRotateToFitInvert': dualPageRotateToFitInvert,
    'doublePageSingleFirstPage': doublePageSingleFirstPage,
    'doublePageAuto': doublePageAuto,
    'landscapeZoom': landscapeZoom,
    'zoomStartPosition': zoomStartPosition,
    'navigateToPan': navigateToPan,
    'tappingInversion': tappingInversion,
    'flashOnPageChange': flashOnPageChange,
    'flashDurationMs': flashDurationMs,
    'flashInterval': flashInterval,
    'flashColor': flashColor,
    'showNavigationOverlayOnStart': showNavigationOverlayOnStart,
    'webtoonDisableZoomOut': webtoonDisableZoomOut,
    'webtoonDoubleTapZoomEnabled': webtoonDoubleTapZoomEnabled,
    'readerHideThreshold': readerHideThreshold,
    'autoScrollEnabled': autoScrollEnabled,
    'autoScrollSpeed': autoScrollSpeed,
    'chapterSwipeStartAction': chapterSwipeStartAction.name,
    'chapterSwipeEndAction': chapterSwipeEndAction.name,
    'personalReaderModes': personalReaderModes.map(
      (key, value) => MapEntry(key, value.name),
    ),
    'personalDoublePage': personalDoublePage,
    'personalAutoScrollEnabled': personalAutoScrollEnabled,
    'personalAutoScrollSpeed': personalAutoScrollSpeed,
  };

  factory MangaReaderSettings.fromJson(Map<String, dynamic> json) {
    T enumValue<T extends Enum>(List<T> values, dynamic raw, T fallback) {
      final name = raw?.toString();
      for (final value in values) {
        if (value.name == name) return value;
      }
      return fallback;
    }

    bool boolean(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    int integer(String key, int fallback) =>
        json[key] is num ? (json[key] as num).toInt() : fallback;
    double number(String key, double fallback) =>
        json[key] is num ? (json[key] as num).toDouble() : fallback;
    Map<String, MangaReaderMode> readerModeMap(dynamic raw) {
      if (raw is! Map) return const <String, MangaReaderMode>{};
      final result = <String, MangaReaderMode>{};
      for (final entry in raw.entries) {
        final key = entry.key.toString().trim();
        if (key.isEmpty) continue;
        result[key] = enumValue(
          MangaReaderMode.values,
          entry.value,
          MangaReaderMode.vertical,
        );
      }
      return result;
    }
    Map<String, bool> boolMap(dynamic raw) {
      if (raw is! Map) return const <String, bool>{};
      return <String, bool>{
        for (final entry in raw.entries)
          if (entry.key.toString().trim().isNotEmpty && entry.value is bool)
            entry.key.toString().trim(): entry.value as bool,
      };
    }
    Map<String, double> speedMap(dynamic raw) {
      if (raw is! Map) return const <String, double>{};
      return <String, double>{
        for (final entry in raw.entries)
          if (entry.key.toString().trim().isNotEmpty && entry.value is num)
            entry.key.toString().trim():
                (entry.value as num).toDouble().clamp(2, 30).toDouble(),
      };
    }

    return MangaReaderSettings(
      defaultMode: enumValue(
        MangaReaderMode.values,
        json['defaultMode'],
        MangaReaderMode.vertical,
      ),
      animatePageTransitions: boolean('animatePageTransitions', true),
      doubleTapAnimationSpeed: integer('doubleTapAnimationSpeed', 1),
      cropBorders: boolean('cropBorders', false),
      scaleType: enumValue(
        MangaReaderScaleType.values,
        json['scaleType'],
        MangaReaderScaleType.fitScreen,
      ),
      pagePreloadAmount: integer('pagePreloadAmount', 6).clamp(0, 20).toInt(),
      background: enumValue(
        MangaReaderBackground.values,
        json['background'],
        MangaReaderBackground.black,
      ),
      usePageTapZones: boolean('usePageTapZones', true),
      fullScreen: boolean('fullScreen', true),
      showPageNumber: boolean('showPageNumber', true),
      keepScreenOn: boolean('keepScreenOn', true),
      webtoonSidePadding: integer('webtoonSidePadding', 0).clamp(0, 50).toInt(),
      showPageGaps: boolean('showPageGaps', true),
      autoReadDuplicateChapters:
          boolean('autoReadDuplicateChapters', false),
      invertColors: boolean('invertColors', false),
      grayscale: boolean('grayscale', false),
      brightness: number('brightness', 0).clamp(-1, 1).toDouble(),
      contrast: number('contrast', 1).clamp(0, 2).toDouble(),
      saturation: number('saturation', 1).clamp(0, 2).toDouble(),
      enableCustomColorFilter: boolean('enableCustomColorFilter', false),
      customColorFilterArgb: integer('customColorFilterArgb', 0x00000000),
      colorFilterBlendMode: enumValue(
        MangaReaderColorBlendMode.values,
        json['colorFilterBlendMode'],
        MangaReaderColorBlendMode.none,
      ),
      navigationLayout: integer('navigationLayout', 0).clamp(0, 5).toInt(),
      splitWidePages: boolean('splitWidePages', false),
      dualPageInvert: boolean('dualPageInvert', false),
      dualPageRotateToFit: boolean('dualPageRotateToFit', false),
      dualPageRotateToFitInvert:
          boolean('dualPageRotateToFitInvert', false),
      doublePageSingleFirstPage:
          boolean('doublePageSingleFirstPage', false),
      doublePageAuto: boolean('doublePageAuto', false),
      landscapeZoom: boolean('landscapeZoom', false),
      zoomStartPosition: integer('zoomStartPosition', 1).clamp(0, 2).toInt(),
      navigateToPan: boolean('navigateToPan', true),
      tappingInversion: integer('tappingInversion', 0).clamp(0, 3).toInt(),
      flashOnPageChange: boolean('flashOnPageChange', false),
      flashDurationMs: integer('flashDurationMs', 100).clamp(50, 500).toInt(),
      flashInterval: integer('flashInterval', 1).clamp(1, 10).toInt(),
      flashColor: integer('flashColor', 0).clamp(0, 2).toInt(),
      showNavigationOverlayOnStart:
          boolean('showNavigationOverlayOnStart', false),
      webtoonDisableZoomOut: boolean('webtoonDisableZoomOut', false),
      webtoonDoubleTapZoomEnabled:
          boolean('webtoonDoubleTapZoomEnabled', true),
      readerHideThreshold: integer('readerHideThreshold', 1).clamp(0, 3).toInt(),
      autoScrollEnabled: boolean('autoScrollEnabled', false),
      autoScrollSpeed: number('autoScrollSpeed', 10).clamp(2, 30).toDouble(),
      chapterSwipeStartAction: enumValue(
        MangaReaderChapterSwipeAction.values,
        json['chapterSwipeStartAction'],
        MangaReaderChapterSwipeAction.toggleBookmark,
      ),
      chapterSwipeEndAction: enumValue(
        MangaReaderChapterSwipeAction.values,
        json['chapterSwipeEndAction'],
        MangaReaderChapterSwipeAction.toggleRead,
      ),
      personalReaderModes: readerModeMap(json['personalReaderModes']),
      personalDoublePage: boolMap(json['personalDoublePage']),
      personalAutoScrollEnabled: boolMap(json['personalAutoScrollEnabled']),
      personalAutoScrollSpeed: speedMap(json['personalAutoScrollSpeed']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MangaReaderSettings &&
          jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

@immutable
class MangaReaderLandscapeZoomTarget {
  const MangaReaderLandscapeZoomTarget({
    required this.scale,
    required this.focalPoint,
  });

  final double scale;
  final Offset focalPoint;
}

int mangaReaderRotateQuarterTurns({
  required MangaReaderSettings settings,
  required Size imageSize,
}) {
  if (!settings.dualPageRotateToFit ||
      imageSize.width <= 0 ||
      imageSize.height <= 0 ||
      imageSize.width <= imageSize.height) {
    return 0;
  }
  return settings.dualPageRotateToFitInvert ? 3 : 1;
}

MangaReaderLandscapeZoomTarget? mangaReaderLandscapeZoomTarget({
  required MangaReaderSettings settings,
  required Size imageSize,
  required Size viewport,
}) {
  if (!settings.landscapeZoom ||
      settings.scaleType != MangaReaderScaleType.fitScreen ||
      imageSize.width <= imageSize.height ||
      imageSize.width <= 0 ||
      imageSize.height <= 0 ||
      viewport.width <= 0 ||
      viewport.height <= 0) {
    return null;
  }

  final fitScreenScale = math.min(
    viewport.width / imageSize.width,
    viewport.height / imageSize.height,
  );
  if (fitScreenScale <= 0) return null;
  final fitHeightScale = viewport.height / imageSize.height;
  final scale = fitHeightScale / fitScreenScale;
  if (!scale.isFinite || scale <= 1.01) return null;

  final focalPoint = switch (settings.zoomStartPosition) {
    0 => Offset.zero,
    1 => Offset(viewport.width, 0),
    _ => viewport.center(Offset.zero),
  };
  return MangaReaderLandscapeZoomTarget(
    scale: scale,
    focalPoint: focalPoint,
  );
}

List<MangaReaderPageSlice> mangaReaderWidePageSlices({
  required MangaReaderSettings settings,
  required bool isWide,
  required bool isRtl,
  required bool doublePageActive,
}) {
  if (!settings.splitWidePages || !isWide || doublePageActive) {
    return const <MangaReaderPageSlice>[MangaReaderPageSlice.full];
  }
  final rightFirst = isRtl ^ settings.dualPageInvert;
  return rightFirst
      ? const <MangaReaderPageSlice>[
          MangaReaderPageSlice.right,
          MangaReaderPageSlice.left,
        ]
      : const <MangaReaderPageSlice>[
          MangaReaderPageSlice.left,
          MangaReaderPageSlice.right,
        ];
}

Duration mangaReaderDoubleTapAnimationDuration(int speed) => switch (speed) {
  0 => const Duration(milliseconds: 10),
  1 => const Duration(milliseconds: 800),
  _ => const Duration(milliseconds: 200),
};

double mangaReaderHideThresholdPixels(int index) => switch (index) {
  0 => 5,
  1 => 13,
  2 => 31,
  _ => 47,
};

double mangaReaderPreloadCacheExtent({
  required MangaReaderSettings settings,
  required Size viewport,
  required Axis axis,
}) {
  final mainAxisExtent = axis == Axis.horizontal
      ? viewport.width
      : viewport.height;
  return settings.pagePreloadAmount.clamp(1, 20) * 0.8 * mainAxisExtent;
}

bool shouldUseMangaDoublePage({
  required MangaReaderSettings settings,
  required Size viewport,
  required MangaReaderMode mode,
  bool forceDoublePage = false,
}) {
  final horizontalContinuous =
      mode == MangaReaderMode.horizontalContinuous ||
      mode == MangaReaderMode.horizontalContinuousRtl;
  if (horizontalContinuous) return false;
  if (forceDoublePage) return true;
  return settings.doublePageAuto && viewport.width > viewport.height;
}

List<List<int>> mangaReaderPageSpreads({
  required int pageCount,
  required bool singleFirst,
}) {
  if (pageCount <= 0) return const <List<int>>[];
  final result = <List<int>>[];
  var index = 0;
  if (singleFirst) {
    result.add(const <int>[0]);
    index = 1;
  }
  while (index < pageCount) {
    final pair = <int>[index];
    if (index + 1 < pageCount) pair.add(index + 1);
    result.add(List<int>.unmodifiable(pair));
    index += 2;
  }
  return List<List<int>>.unmodifiable(result);
}


String mangaReaderPageLabel({
  required int pageIndex,
  required int pageCount,
  required bool doublePage,
  required bool singleFirst,
}) {
  if (pageCount <= 0) return '0';
  final safeIndex = pageIndex.clamp(0, pageCount - 1).toInt();
  if (!doublePage) return '${safeIndex + 1}';

  final spreads = mangaReaderPageSpreads(
    pageCount: pageCount,
    singleFirst: singleFirst,
  );
  for (final spread in spreads) {
    if (!spread.contains(safeIndex)) continue;
    return spread.map((index) => '${index + 1}').join('-');
  }
  return '${safeIndex + 1}';
}

const List<double> identityMangaReaderColorMatrix = <double>[
  1, 0, 0, 0, 0,
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0,
];

List<double> _multiplyColorMatrices(List<double> a, List<double> b) {
  final result = List<double>.filled(20, 0);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 4; col++) {
      var value = 0.0;
      for (var k = 0; k < 4; k++) {
        value += a[row * 5 + k] * b[k * 5 + col];
      }
      result[row * 5 + col] = value;
    }
    var offset = a[row * 5 + 4];
    for (var k = 0; k < 4; k++) {
      offset += a[row * 5 + k] * b[k * 5 + 4];
    }
    result[row * 5 + 4] = offset;
  }
  return result;
}

List<double> mangaReaderColorMatrix(MangaReaderSettings settings) {
  var matrix = List<double>.of(identityMangaReaderColorMatrix);

  final saturation = settings.grayscale ? 0.0 : settings.saturation;
  const lr = 0.2126;
  const lg = 0.7152;
  const lb = 0.0722;
  final invSat = 1 - saturation;
  final sr = invSat * lr;
  final sg = invSat * lg;
  final sb = invSat * lb;
  matrix = _multiplyColorMatrices(<double>[
    sr + saturation, sg, sb, 0, 0,
    sr, sg + saturation, sb, 0, 0,
    sr, sg, sb + saturation, 0, 0,
    0, 0, 0, 1, 0,
  ], matrix);

  final contrast = settings.contrast;
  final contrastOffset = 128 * (1 - contrast);
  matrix = _multiplyColorMatrices(<double>[
    contrast, 0, 0, 0, contrastOffset,
    0, contrast, 0, 0, contrastOffset,
    0, 0, contrast, 0, contrastOffset,
    0, 0, 0, 1, 0,
  ], matrix);

  final brightnessOffset = settings.brightness * 255;
  matrix = _multiplyColorMatrices(<double>[
    1, 0, 0, 0, brightnessOffset,
    0, 1, 0, 0, brightnessOffset,
    0, 0, 1, 0, brightnessOffset,
    0, 0, 0, 1, 0,
  ], matrix);

  if (settings.invertColors) {
    matrix = _multiplyColorMatrices(const <double>[
      -1, 0, 0, 0, 255,
      0, -1, 0, 0, 255,
      0, 0, -1, 0, 255,
      0, 0, 0, 1, 0,
    ], matrix);
  }

  return matrix;
}
