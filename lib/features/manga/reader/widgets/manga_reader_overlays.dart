// Adapted from Mangayomi's ReaderOverlays (Apache-2.0).
// See docs/third_party/MANGAYOMI_READER_NOTICE.md.
import 'package:flutter/material.dart';

import '../manga_reader_settings.dart';
import 'manga_reader_gesture_handler.dart';
import 'manga_reader_navigation_overlay.dart';

class MangaReaderOverlays extends StatelessWidget {
  const MangaReaderOverlays({
    super.key,
    required this.settings,
    required this.isRtl,
    required this.isContinuousMode,
    required this.onToggleUi,
    required this.onPreviousPage,
    required this.onNextPage,
    required this.isFlashing,
    required this.flashOverlayColor,
    required this.showNavigationOverlay,
    required this.onCloseNavigationOverlay,
    this.hasImageError = false,
  });

  final MangaReaderSettings settings;
  final bool isRtl;
  final bool hasImageError;
  final bool isContinuousMode;
  final VoidCallback onToggleUi;
  final VoidCallback onPreviousPage;
  final VoidCallback onNextPage;
  final bool isFlashing;
  final Color flashOverlayColor;
  final bool showNavigationOverlay;
  final VoidCallback onCloseNavigationOverlay;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: MangaReaderGestureHandler(
            usePageTapZones: settings.usePageTapZones,
            navigationLayout: settings.navigationLayout,
            tappingInversion: settings.tappingInversion,
            isRtl: isRtl,
            hasImageError: hasImageError,
            isContinuousMode: isContinuousMode,
            onToggleUi: onToggleUi,
            onPreviousPage: onPreviousPage,
            onNextPage: onNextPage,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: isFlashing ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeInOut,
              child: ColoredBox(color: flashOverlayColor),
            ),
          ),
        ),
        if (showNavigationOverlay)
          Positioned.fill(
            child: MangaReaderNavigationOverlay(
              navigationLayout: settings.navigationLayout,
              tappingInversion: settings.tappingInversion,
              isRtl: isRtl,
              onClose: onCloseNavigationOverlay,
            ),
          ),
      ],
    );
  }
}
