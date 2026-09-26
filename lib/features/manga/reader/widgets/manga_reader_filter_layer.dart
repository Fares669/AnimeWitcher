import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../manga_reader_settings.dart';

/// The page as the reader's filter tab sets it, the way Mihon draws it: in
/// grey or with its colours inverted, under a tint mixed in by the chosen
/// blend, and dimmed below the screen's own brightness.
class MangaReaderFilterLayer extends StatelessWidget {
  const MangaReaderFilterLayer({
    super.key,
    required this.settings,
    required this.child,
  });

  final MangaReaderSettings settings;
  final Widget child;

  static const List<double> _grayscale = <double>[
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0,
  ];

  static const List<double> _invert = <double>[
    -1, 0, 0, 0, 255, //
    0, -1, 0, 0, 255, //
    0, 0, -1, 0, 255, //
    0, 0, 0, 1, 0,
  ];

  @override
  Widget build(BuildContext context) {
    var page = child;
    if (settings.grayscale) {
      page = ColorFiltered(
        colorFilter: const ColorFilter.matrix(_grayscale),
        child: page,
      );
    }
    if (settings.invertedColors) {
      page = ColorFiltered(
        colorFilter: const ColorFilter.matrix(_invert),
        child: page,
      );
    }
    if (settings.colorFilter) {
      page = ColorFiltered(
        key: const ValueKey<String>('manga-reader-color-filter'),
        colorFilter: ColorFilter.mode(
          Color(settings.colorFilterValue),
          mangaReaderBlendMode(settings.colorFilterMode),
        ),
        child: page,
      );
    }
    final dim = mangaReaderDimAlpha(settings);
    if (dim <= 0) return page;
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        page,
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(
              key: const ValueKey<String>('manga-reader-dim'),
              color: Colors.black.withValues(alpha: dim),
            ),
          ),
        ),
      ],
    );
  }
}

/// How dark the dimming over the page is, 0 when custom brightness is off.
double mangaReaderDimAlpha(MangaReaderSettings settings) {
  if (!settings.customBrightness || settings.brightness >= 0) return 0;
  return (-settings.brightness / 100).clamp(0.0, 0.75);
}

BlendMode mangaReaderBlendMode(MangaReaderColorBlend blend) => switch (blend) {
  // "Normal" lays the tint over the page; its alpha lets the page through.
  MangaReaderColorBlend.normal => BlendMode.srcATop,
  MangaReaderColorBlend.multiply => BlendMode.multiply,
  MangaReaderColorBlend.screen => BlendMode.screen,
  MangaReaderColorBlend.overlay => BlendMode.overlay,
  MangaReaderColorBlend.lighten => BlendMode.lighten,
  MangaReaderColorBlend.darken => BlendMode.darken,
};

/// The screen turnings a reading orientation allows; empty lets the device
/// decide, as it does everywhere else in the app.
List<DeviceOrientation> mangaReaderOrientations(
  MangaReaderOrientation orientation,
) => switch (orientation) {
  MangaReaderOrientation.free => const <DeviceOrientation>[],
  // Upright or on its side, whichever way up the device is held.
  MangaReaderOrientation.portrait => const <DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ],
  MangaReaderOrientation.landscape => const <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ],
  // Held one way only.
  MangaReaderOrientation.lockedPortrait => const <DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ],
  MangaReaderOrientation.lockedLandscape => const <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
  ],
  MangaReaderOrientation.reversePortrait => const <DeviceOrientation>[
    DeviceOrientation.portraitDown,
  ],
};
