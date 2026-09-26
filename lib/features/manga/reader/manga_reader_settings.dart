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

enum MangaReaderChapterSwipeAction {
  toggleBookmark,
  toggleRead,
  download,
  disabled,
}

enum MangaReaderPageSlice { full, left, right }

/// How the screen may turn while reading, Mihon's choices: with the device,
/// upright or on its side either way up, or held one way only. Phones and
/// tablets only.
enum MangaReaderOrientation {
  free,
  portrait,
  landscape,
  lockedPortrait,
  lockedLandscape,
  reversePortrait,
}

/// How the colour filter mixes with the page, Mihon's blend modes.
enum MangaReaderColorBlend {
  normal,
  multiply,
  screen,
  overlay,
  lighten,
  darken,
}

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
    this.verticalPageBar = false,
    this.customBrightness = false,
    this.brightness = 0,
    this.colorFilter = false,
    this.colorFilterValue = 0x40FF9800,
    this.colorFilterMode = MangaReaderColorBlend.normal,
    this.grayscale = false,
    this.invertedColors = false,
    this.defaultOrientation = MangaReaderOrientation.free,
    this.readWithVolumeKeys = false,
    this.readWithVolumeKeysInverted = false,
    this.showReadingMode = true,
    this.verticalBarModes = const <MangaReaderMode>{},
    this.verticalBarLeft = false,
    this.verticalBarHeight = 100,
    this.showActionsOnLongTap = true,
    this.webtoonDisableZoomOut = false,
    this.webtoonDoubleTapZoomEnabled = true,
    this.readerHideThreshold = 1,
    this.autoScrollEnabled = false,
    this.autoScrollSpeed = 10,
    this.chapterSwipeStartAction = MangaReaderChapterSwipeAction.toggleBookmark,
    this.chapterSwipeEndAction = MangaReaderChapterSwipeAction.toggleRead,
    this.personalReaderModes = const <String, MangaReaderMode>{},
    this.personalDoublePage = const <String, bool>{},
    this.personalAutoScrollEnabled = const <String, bool>{},
    this.personalAutoScrollSpeed = const <String, double>{},
    this.personalOrientation = const <String, MangaReaderOrientation>{},
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

  /// The page bar down the side of the window instead of across its foot.
  final bool verticalPageBar;

  /// Dims the page below the screen's own brightness: 0 leaves it, -75 is
  /// the darkest, as Mihon's custom brightness goes below zero.
  final bool customBrightness;
  final int brightness;

  /// A tint laid over the page, mixed by [colorFilterMode]; its alpha is
  /// how strong it is.
  final bool colorFilter;
  final int colorFilterValue;
  final MangaReaderColorBlend colorFilterMode;
  final bool grayscale;
  final bool invertedColors;

  /// The screen's turning for a manga with none of its own.
  final MangaReaderOrientation defaultOrientation;

  /// The volume keys turn pages; inverted, down goes back.
  final bool readWithVolumeKeys;
  final bool readWithVolumeKeysInverted;

  /// The reading mode's name, shown for a moment as a chapter opens.
  final bool showReadingMode;

  /// The modes that use the vertical chapter navigator down the side in
  /// place of the page bar at the foot, as Mihon picks them.
  final Set<MangaReaderMode> verticalBarModes;

  /// The vertical navigator on the left edge rather than the right.
  final bool verticalBarLeft;

  /// How much of the screen's height the vertical navigator takes, in
  /// percent.
  final int verticalBarHeight;

  /// A long press opens the page's actions — save, share, set as cover —
  /// rather than showing or hiding the bars.
  final bool showActionsOnLongTap;

  bool usesVerticalBar(MangaReaderMode mode) => verticalBarModes.contains(mode);
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
  final Map<String, MangaReaderOrientation> personalOrientation;

  MangaReaderOrientation orientationForManga(String mangaId) =>
      personalOrientation[mangaId.trim()] ?? defaultOrientation;

  /// Whether this manga has a mode, or a turning, of its own rather than
  /// the default.
  bool hasOwnMode(String mangaId) =>
      personalReaderModes.containsKey(mangaId.trim());
  bool hasOwnOrientation(String mangaId) =>
      personalOrientation.containsKey(mangaId.trim());

  /// Back to the default mode for this manga.
  MangaReaderSettings withoutMangaMode(String mangaId) => copyWith(
    personalReaderModes: <String, MangaReaderMode>{
      for (final entry in personalReaderModes.entries)
        if (entry.key != mangaId.trim()) entry.key: entry.value,
    },
  );

  /// Back to the default turning for this manga.
  MangaReaderSettings withoutMangaOrientation(String mangaId) => copyWith(
    personalOrientation: <String, MangaReaderOrientation>{
      for (final entry in personalOrientation.entries)
        if (entry.key != mangaId.trim()) entry.key: entry.value,
    },
  );

  MangaReaderSettings withMangaOrientation(
    String mangaId,
    MangaReaderOrientation orientation,
  ) {
    final id = mangaId.trim();
    if (id.isEmpty) return this;
    return copyWith(
      personalOrientation: <String, MangaReaderOrientation>{
        ...personalOrientation,
        id: orientation,
      },
    );
  }

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
      personalDoublePage: <String, bool>{...personalDoublePage, id: enabled},
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
    bool? verticalPageBar,
    bool? customBrightness,
    int? brightness,
    bool? colorFilter,
    int? colorFilterValue,
    MangaReaderColorBlend? colorFilterMode,
    bool? grayscale,
    bool? invertedColors,
    MangaReaderOrientation? defaultOrientation,
    bool? readWithVolumeKeys,
    bool? readWithVolumeKeysInverted,
    bool? showReadingMode,
    Set<MangaReaderMode>? verticalBarModes,
    bool? verticalBarLeft,
    int? verticalBarHeight,
    bool? showActionsOnLongTap,
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
    Map<String, MangaReaderOrientation>? personalOrientation,
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
      verticalPageBar: verticalPageBar ?? this.verticalPageBar,
      customBrightness: customBrightness ?? this.customBrightness,
      brightness: brightness ?? this.brightness,
      colorFilter: colorFilter ?? this.colorFilter,
      colorFilterValue: colorFilterValue ?? this.colorFilterValue,
      colorFilterMode: colorFilterMode ?? this.colorFilterMode,
      grayscale: grayscale ?? this.grayscale,
      invertedColors: invertedColors ?? this.invertedColors,
      defaultOrientation: defaultOrientation ?? this.defaultOrientation,
      readWithVolumeKeys: readWithVolumeKeys ?? this.readWithVolumeKeys,
      readWithVolumeKeysInverted:
          readWithVolumeKeysInverted ?? this.readWithVolumeKeysInverted,
      showReadingMode: showReadingMode ?? this.showReadingMode,
      verticalBarModes: verticalBarModes ?? this.verticalBarModes,
      verticalBarLeft: verticalBarLeft ?? this.verticalBarLeft,
      verticalBarHeight: verticalBarHeight ?? this.verticalBarHeight,
      showActionsOnLongTap: showActionsOnLongTap ?? this.showActionsOnLongTap,
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
      personalOrientation: personalOrientation ?? this.personalOrientation,
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
    'verticalPageBar': verticalPageBar,
    'customBrightness': customBrightness,
    'brightness': brightness,
    'colorFilter': colorFilter,
    'colorFilterValue': colorFilterValue,
    'colorFilterMode': colorFilterMode.name,
    'grayscale': grayscale,
    'invertedColors': invertedColors,
    'defaultOrientation': defaultOrientation.name,
    'readWithVolumeKeys': readWithVolumeKeys,
    'readWithVolumeKeysInverted': readWithVolumeKeysInverted,
    'showReadingMode': showReadingMode,
    'verticalBarModes': <String>[
      for (final mode in MangaReaderMode.values)
        if (verticalBarModes.contains(mode)) mode.name,
    ],
    'verticalBarLeft': verticalBarLeft,
    'verticalBarHeight': verticalBarHeight,
    'showActionsOnLongTap': showActionsOnLongTap,
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
    'personalOrientation': personalOrientation.map(
      (key, value) => MapEntry(key, value.name),
    ),
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

    Map<String, MangaReaderOrientation> orientationMap(dynamic raw) {
      if (raw is! Map) return const <String, MangaReaderOrientation>{};
      return <String, MangaReaderOrientation>{
        for (final entry in raw.entries)
          if (entry.key.toString().trim().isNotEmpty)
            entry.key.toString().trim(): enumValue(
              MangaReaderOrientation.values,
              entry.value,
              MangaReaderOrientation.free,
            ),
      };
    }

    Map<String, double> speedMap(dynamic raw) {
      if (raw is! Map) return const <String, double>{};
      return <String, double>{
        for (final entry in raw.entries)
          if (entry.key.toString().trim().isNotEmpty && entry.value is num)
            entry.key.toString().trim(): (entry.value as num)
                .toDouble()
                .clamp(2, 30)
                .toDouble(),
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
      autoReadDuplicateChapters: boolean('autoReadDuplicateChapters', false),
      navigationLayout: integer('navigationLayout', 0).clamp(0, 5).toInt(),
      splitWidePages: boolean('splitWidePages', false),
      dualPageInvert: boolean('dualPageInvert', false),
      dualPageRotateToFit: boolean('dualPageRotateToFit', false),
      dualPageRotateToFitInvert: boolean('dualPageRotateToFitInvert', false),
      doublePageSingleFirstPage: boolean('doublePageSingleFirstPage', false),
      doublePageAuto: boolean('doublePageAuto', false),
      landscapeZoom: boolean('landscapeZoom', false),
      zoomStartPosition: integer('zoomStartPosition', 1).clamp(0, 2).toInt(),
      navigateToPan: boolean('navigateToPan', true),
      tappingInversion: integer('tappingInversion', 0).clamp(0, 3).toInt(),
      flashOnPageChange: boolean('flashOnPageChange', false),
      flashDurationMs: integer('flashDurationMs', 100).clamp(50, 500).toInt(),
      flashInterval: integer('flashInterval', 1).clamp(1, 10).toInt(),
      flashColor: integer('flashColor', 0).clamp(0, 2).toInt(),
      showNavigationOverlayOnStart: boolean(
        'showNavigationOverlayOnStart',
        false,
      ),
      verticalPageBar: boolean('verticalPageBar', false),
      customBrightness: boolean('customBrightness', false),
      brightness: integer('brightness', 0).clamp(-75, 0).toInt(),
      colorFilter: boolean('colorFilter', false),
      colorFilterValue: integer('colorFilterValue', 0x40FF9800),
      colorFilterMode: enumValue(
        MangaReaderColorBlend.values,
        json['colorFilterMode'],
        MangaReaderColorBlend.normal,
      ),
      grayscale: boolean('grayscale', false),
      invertedColors: boolean('invertedColors', false),
      defaultOrientation: enumValue(
        MangaReaderOrientation.values,
        json['defaultOrientation'],
        MangaReaderOrientation.free,
      ),
      readWithVolumeKeys: boolean('readWithVolumeKeys', false),
      readWithVolumeKeysInverted: boolean('readWithVolumeKeysInverted', false),
      showReadingMode: boolean('showReadingMode', true),
      verticalBarModes: () {
        final raw = json['verticalBarModes'];
        if (raw is List) {
          return <MangaReaderMode>{
            for (final value in raw)
              for (final mode in MangaReaderMode.values)
                if (mode.name == value) mode,
          };
        }
        // Saved before the choice was per mode: the one switch covered them
        // all.
        return boolean('verticalPageBar', false)
            ? MangaReaderMode.values.toSet()
            : const <MangaReaderMode>{};
      }(),
      verticalBarLeft: boolean('verticalBarLeft', false),
      verticalBarHeight: integer(
        'verticalBarHeight',
        100,
      ).clamp(50, 100).toInt(),
      showActionsOnLongTap: boolean('showActionsOnLongTap', true),
      webtoonDisableZoomOut: boolean('webtoonDisableZoomOut', false),
      webtoonDoubleTapZoomEnabled: boolean('webtoonDoubleTapZoomEnabled', true),
      readerHideThreshold: integer(
        'readerHideThreshold',
        1,
      ).clamp(0, 3).toInt(),
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
      personalOrientation: orientationMap(json['personalOrientation']),
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
  return MangaReaderLandscapeZoomTarget(scale: scale, focalPoint: focalPoint);
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
