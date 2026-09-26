import 'dart:math' as math;

import 'package:animewitcher/core/theme/app_theme.dart';
import 'package:animewitcher/core/theme/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  test('every theme is found again by its saved name', () {
    for (final style in AppThemeStyle.values) {
      expect(AppThemeStyle.fromName(style.name), style);
    }
  });

  test('every tinted theme draws in its own accent', () {
    for (final style in AppThemeStyle.values) {
      final palette = AppTheme.paletteFor(style);
      if (palette == null) continue;
      final theme = AppTheme.darkThemeFor(style, null);
      expect(theme.colorScheme.primary, palette.accent, reason: style.name);
      expect(theme.scaffoldBackgroundColor, palette.background);
      expect(theme.brightness, Brightness.dark, reason: style.name);
      expect(style.swatch, palette.accent);
    }
  });

  test('text stays readable in every tinted theme', () {
    for (final style in AppThemeStyle.values) {
      final palette = AppTheme.paletteFor(style);
      if (palette == null) continue;
      // Labels on the accent, like a selected chip or a filled button.
      expect(
        _contrast(palette.accent, palette.onAccent),
        greaterThanOrEqualTo(4.5),
        reason: '${style.name}: text on the accent',
      );
      // Muted text on the page.
      expect(
        _contrast(palette.muted, palette.background),
        greaterThanOrEqualTo(4.5),
        reason: '${style.name}: muted text',
      );
      // A chosen item's text on its fill.
      expect(
        _contrast(palette.onSelected, palette.selected),
        greaterThanOrEqualTo(4.5),
        reason: '${style.name}: selected text',
      );
    }
  });

  test('tinted component surfaces and selection colors follow the palette', () {
    for (final style in AppThemeStyle.values) {
      final palette = AppTheme.paletteFor(style);
      if (palette == null) continue;
      final theme = AppTheme.darkThemeFor(style, null);

      expect(
        theme.popupMenuTheme.color,
        palette.surfaceHighest,
        reason: '${style.name}: popup surface',
      );
      expect(
        theme.menuTheme.style?.backgroundColor?.resolve(<WidgetState>{}),
        palette.surfaceHighest,
        reason: '${style.name}: menu surface',
      );
      expect(
        theme.chipTheme.backgroundColor,
        palette.surface,
        reason: '${style.name}: chip surface',
      );
      expect(
        theme.chipTheme.selectedColor,
        palette.accent.withValues(alpha: 0.18),
        reason: '${style.name}: selected chip',
      );
      expect(
        theme.chipTheme.secondaryLabelStyle?.color,
        palette.accent,
        reason: '${style.name}: selected chip label',
      );
      expect(
        theme.sliderTheme.activeTrackColor,
        palette.accent,
        reason: '${style.name}: slider track',
      );
      expect(
        theme.sliderTheme.thumbColor,
        palette.accent,
        reason: '${style.name}: slider thumb',
      );
      expect(
        theme.textSelectionTheme.cursorColor,
        palette.accent,
        reason: '${style.name}: text caret',
      );
      expect(
        theme.splashColor,
        palette.accent.withValues(alpha: 0.10),
        reason: '${style.name}: press splash',
      );
      expect(
        theme.focusColor,
        palette.accent.withValues(alpha: 0.12),
        reason: '${style.name}: focus overlay',
      );
      expect(
        (theme.inputDecorationTheme.focusedBorder as OutlineInputBorder)
            .borderSide
            .color,
        palette.accent,
        reason: '${style.name}: focused input outline',
      );
    }
  });

  test('AMOLED is true black', () {
    expect(AppTheme.amoledPalette.background, const Color(0xFF000000));
  });
}
