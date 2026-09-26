// Adapted from Mangayomi's ReaderKeyboardHandler (Apache-2.0).
// See docs/third_party/MANGAYOMI_READER_NOTICE.md.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MangaReaderKeyboardHandler {
  const MangaReaderKeyboardHandler({
    this.onEscape,
    this.onFullScreen,
    this.onPreviousPage,
    this.onNextPage,
    this.onNextChapter,
    this.onPreviousChapter,
  });

  final VoidCallback? onEscape;
  final VoidCallback? onFullScreen;
  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;
  final VoidCallback? onNextChapter;
  final VoidCallback? onPreviousChapter;

  /// Handles [event], and says whether it was one of the reader's keys.
  ///
  /// With [volumeKeys] on, volume down turns to the next page and up to
  /// the one before, as Mihon has them; [volumeKeysInverted] swaps them.
  bool handleKeyEvent(
    KeyEvent event, {
    bool isReverseHorizontal = false,
    bool volumeKeys = false,
    bool volumeKeysInverted = false,
  }) {
    final key = event.logicalKey;
    final isVolume =
        key == LogicalKeyboardKey.audioVolumeDown ||
        key == LogicalKeyboardKey.audioVolumeUp;
    if (isVolume) {
      if (!volumeKeys) return false;
      // Held or released, still the reader's: the volume must not move.
      if (event is! KeyDownEvent) return true;
      final forward =
          (key == LogicalKeyboardKey.audioVolumeDown) != volumeKeysInverted;
      (forward ? onNextPage : onPreviousPage)?.call();
      return true;
    }
    if (event is! KeyDownEvent) return false;
    switch (key) {
      case LogicalKeyboardKey.f11:
        onFullScreen?.call();
        return true;
      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.backspace:
        onEscape?.call();
        return true;
      case LogicalKeyboardKey.arrowUp:
        onPreviousPage?.call();
        return true;
      case LogicalKeyboardKey.arrowDown:
        onNextPage?.call();
        return true;
      case LogicalKeyboardKey.arrowLeft:
        if (isReverseHorizontal) {
          onNextPage?.call();
        } else {
          onPreviousPage?.call();
        }
        return true;
      case LogicalKeyboardKey.arrowRight:
        if (isReverseHorizontal) {
          onPreviousPage?.call();
        } else {
          onNextPage?.call();
        }
        return true;
      case LogicalKeyboardKey.keyN:
      case LogicalKeyboardKey.pageDown:
      case LogicalKeyboardKey.shiftRight:
        onNextChapter?.call();
        return true;
      case LogicalKeyboardKey.keyP:
      case LogicalKeyboardKey.pageUp:
      case LogicalKeyboardKey.shiftLeft:
        onPreviousChapter?.call();
        return true;
      default:
        return false;
    }
  }

  Widget wrapWithKeyboardListener({
    required Widget child,
    bool isReverseHorizontal = false,
    bool volumeKeys = false,
    bool volumeKeysInverted = false,
    required FocusNode focusNode,
  }) {
    // A handled key stops here, so the system does not also act on it:
    // the volume keys turn the page without changing the volume.
    return Focus(
      autofocus: true,
      focusNode: focusNode,
      onKeyEvent: (_, event) =>
          handleKeyEvent(
            event,
            isReverseHorizontal: isReverseHorizontal,
            volumeKeys: volumeKeys,
            volumeKeysInverted: volumeKeysInverted,
          )
          ? KeyEventResult.handled
          : KeyEventResult.ignored,
      child: child,
    );
  }
}
