import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'theme_provider.dart';

class _FixedLtrCupertinoPageTransitionsBuilder extends PageTransitionsBuilder {
  const _FixedLtrCupertinoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final contentDirection = Directionality.of(context);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(
        builder: (ltrContext) =>
            CupertinoPageTransitionsBuilder().buildTransitions<T>(
              route,
              ltrContext,
              animation,
              secondaryAnimation,
              Directionality(textDirection: contentDirection, child: child),
            ),
      ),
    );
  }
}

class AppTheme {
  /// The app's typeface, bundled under assets/fonts with every weight the
  /// app uses. One family with real 500, 600 and 700 files: fetched through
  /// google_fonts each weight was a family of its own, so text set bold on
  /// top of the theme drew the regular file and came out thin.
  static const String appFontFamily = 'Readex Pro';

  static TextStyle _appFont({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? letterSpacing,
  }) => TextStyle(
    fontFamily: appFontFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    letterSpacing: letterSpacing,
  );

  static final PageTransitionsTheme _pageTransitionsTheme =
      PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          ...const PageTransitionsTheme().builders,
          TargetPlatform.iOS: const _FixedLtrCupertinoPageTransitionsBuilder(),
        },
      );
  // AnimeWitcher palette. The official Android app uses #EEC60A as
  // colorAccent across interactive controls, tabs, selection states and progress.
  static const Color animeWitcherAccent = Color(0xFFEEC60A);
  static const Color animeWitcherAccentTransparent = Color(0xAEEEC60A);

  // Premium Colors
  static const Color background = Color(0xFF0F0F13); // Deep dark blue-grey
  static const Color surface = Color(0xFF18181F);
  static const Color surfaceHighlight = Color(0xFF22222E);
  static const Color primary = animeWitcherAccent;
  static const Color primaryVariant = animeWitcherAccent;
  static const Color secondary = animeWitcherAccent;
  static const Color error = Color(0xFFEF4444);
  static const Color onSurface = Color(0xFFE5E7EB);
  static const Color textSecondary = Color(0xFF9CA3AF);

  // Light Theme Colors
  static const Color lightBackground = Color(0xFFF5F1EC); // primary surface
  static const Color lightSurface = Color(0xFFFAF8F5); // surfaceContainerLowest
  static const Color lightSurfaceHighlight = Color(
    0xFFE8E2D8,
  ); // surfaceContainerHigh
  static const Color lightTextPrimary = Color(0xFF2C2521); // onSurface
  static const Color lightTextSecondary = Color(0xFF5C5C5C); // onSurfaceVariant

  /// Icons and secondary text on the dark theme's pure-black surfaces.
  static const Color darkIconNeutral = Color(0xFFD3D5DC);
  // Kept as a compatibility alias for existing callers/tests.
  static const Color lightCoral = animeWitcherAccent;

  static SnackBarThemeData snackBarThemeFor(ColorScheme colorScheme) {
    final isDark = colorScheme.brightness == Brightness.dark;
    return SnackBarThemeData(
      backgroundColor: isDark ? surface : colorScheme.surfaceContainerHigh,
      contentTextStyle: TextStyle(
        color: isDark ? onSurface : colorScheme.onSurface,
      ),
      actionTextColor: colorScheme.primary,
    );
  }

  /// The hairline every floating surface carries, matching the home search
  /// capsule and the taskbar pill. It is what makes a menu read as part of
  /// the app rather than a plain grey box dropped on top of it.
  /// Extra height for a title bar on a desktop window.
  ///
  /// The window's own controls are painted over the top of the app rather
  /// than in a bar of their own, so a toolbar of the usual height centres its
  /// title exactly where the minimise and close buttons sit. The taller bar
  /// drops the title clear of them; a phone has no such controls and keeps
  /// the standard height.
  static double? get _toolbarHeight {
    if (kIsWeb) return null;
    return Platform.isWindows || Platform.isMacOS ? 72 : null;
  }

  static BorderSide _hairline(ColorScheme scheme) =>
      BorderSide(color: scheme.onSurfaceVariant.withValues(alpha: 0.12));

  /// Menus, sheets and dialogs share one shape so they look like the same
  /// object appearing in different places.
  static const double _surfaceRadius = 16;

  static PopupMenuThemeData _popupMenuTheme(ColorScheme scheme) {
    return PopupMenuThemeData(
      color: scheme.surfaceContainerHighest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(_surfaceRadius),
        side: _hairline(scheme),
      ),
    );
  }

  static MenuThemeData _menuTheme(ColorScheme scheme) {
    return MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(
          scheme.surfaceContainerHighest,
        ),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        elevation: const WidgetStatePropertyAll<double>(0),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_surfaceRadius),
            side: _hairline(scheme),
          ),
        ),
      ),
    );
  }

  // Amber theme: warm charcoal surfaces and an amber accent.
  static const Color amberAccent = Color(0xFFEF9F27);
  static const Color amberOnAccent = Color(0xFF412402);
  static const Color amberBackground = Color(0xFF141412);
  static const Color amberSurface = Color(0xFF1C1B19);
  static const Color amberSurfaceHigh = Color(0xFF232322);
  static const Color amberSurfaceHighest = Color(0xFF2C2C2A);
  static const Color amberSelected = Color(0xFF633806);
  static const Color amberOnSelected = Color(0xFFFAC775);
  static const Color amberMuted = Color(0xFFB4B2A9);

  static const AppDarkPalette amberPalette = AppDarkPalette(
    accent: amberAccent,
    onAccent: amberOnAccent,
    background: amberBackground,
    surface: amberSurface,
    surfaceHigh: amberSurfaceHigh,
    surfaceHighest: amberSurfaceHighest,
    selected: amberSelected,
    onSelected: amberOnSelected,
    muted: amberMuted,
    outline: Color(0xFF3A3936),
  );

  /// True black for OLED screens, with the app's gold.
  static const AppDarkPalette amoledPalette = AppDarkPalette(
    accent: animeWitcherAccent,
    onAccent: Color(0xFF2B2300),
    background: Color(0xFF000000),
    surface: Color(0xFF0A0A0A),
    surfaceHigh: Color(0xFF141414),
    surfaceHighest: Color(0xFF1E1E1E),
    selected: Color(0xFF4A3D00),
    onSelected: Color(0xFFFFE57F),
    muted: Color(0xFFA0A0A0),
    outline: Color(0xFF262626),
  );

  /// Deep navy with sky blue.
  static const AppDarkPalette oceanPalette = AppDarkPalette(
    accent: Color(0xFF4FC3F7),
    onAccent: Color(0xFF01344A),
    background: Color(0xFF0B1320),
    surface: Color(0xFF111B2B),
    surfaceHigh: Color(0xFF172436),
    surfaceHighest: Color(0xFF1E2E44),
    selected: Color(0xFF0E4A6B),
    onSelected: Color(0xFFB3E5FC),
    muted: Color(0xFF9FB3C8),
    outline: Color(0xFF2A3A50),
  );

  /// Pine green with emerald.
  static const AppDarkPalette forestPalette = AppDarkPalette(
    accent: Color(0xFF5DCAA5),
    onAccent: Color(0xFF04342C),
    background: Color(0xFF0C1411),
    surface: Color(0xFF121C18),
    surfaceHigh: Color(0xFF18251F),
    surfaceHighest: Color(0xFF1F2E27),
    selected: Color(0xFF085041),
    onSelected: Color(0xFF9FE1CB),
    muted: Color(0xFFA3B8AE),
    outline: Color(0xFF2B3B33),
  );

  /// Dark plum with cherry-blossom pink.
  static const AppDarkPalette sakuraPalette = AppDarkPalette(
    accent: Color(0xFFF48FB1),
    onAccent: Color(0xFF4B1528),
    background: Color(0xFF160F13),
    surface: Color(0xFF1F161B),
    surfaceHigh: Color(0xFF281C23),
    surfaceHighest: Color(0xFF32232C),
    selected: Color(0xFF72243E),
    onSelected: Color(0xFFF8BBD0),
    muted: Color(0xFFC2A9B5),
    outline: Color(0xFF41303A),
  );

  /// Night indigo with lavender.
  static const AppDarkPalette violetPalette = AppDarkPalette(
    accent: Color(0xFFB39DDB),
    onAccent: Color(0xFF26215C),
    background: Color(0xFF100F1A),
    surface: Color(0xFF171624),
    surfaceHigh: Color(0xFF1E1C2F),
    surfaceHighest: Color(0xFF26233A),
    selected: Color(0xFF3C3489),
    onSelected: Color(0xFFD1C4E9),
    muted: Color(0xFFABA7C4),
    outline: Color(0xFF34304A),
  );

  /// Near black with crimson.
  static const AppDarkPalette crimsonPalette = AppDarkPalette(
    accent: Color(0xFFEF5350),
    onAccent: Color(0xFF2A0606),
    background: Color(0xFF120C0C),
    surface: Color(0xFF1B1313),
    surfaceHigh: Color(0xFF241919),
    surfaceHighest: Color(0xFF2E2020),
    selected: Color(0xFF791F1F),
    onSelected: Color(0xFFFFCDD2),
    muted: Color(0xFFBFA8A8),
    outline: Color(0xFF3D2B2B),
  );

  /// The colours a tinted dark theme is drawn in; null for the app's own
  /// dark and light themes, which are built on their own.
  static AppDarkPalette? paletteFor(AppThemeStyle style) => switch (style) {
    AppThemeStyle.dark || AppThemeStyle.light => null,
    AppThemeStyle.amber => amberPalette,
    AppThemeStyle.amoled => amoledPalette,
    AppThemeStyle.ocean => oceanPalette,
    AppThemeStyle.forest => forestPalette,
    AppThemeStyle.sakura => sakuraPalette,
    AppThemeStyle.violet => violetPalette,
    AppThemeStyle.crimson => crimsonPalette,
  };

  /// The dark theme [style] draws in; the app's own dark theme, from the
  /// device's colours where it has them, when the style has no palette.
  static ThemeData darkThemeFor(AppThemeStyle style, ColorScheme? darkScheme) {
    final palette = paletteFor(style);
    return palette == null
        ? createDarkTheme(darkScheme)
        : createPaletteTheme(palette);
  }

  /// The dark theme redrawn in warm charcoal with an amber accent.
  static ThemeData createAmberTheme() => createPaletteTheme(amberPalette);

  /// The dark theme redrawn in [p]'s colours.
  ///
  /// Built on [createDarkTheme] so it keeps every shape, font and component
  /// setting that theme carries, and only the colours change.
  static ThemeData createPaletteTheme(AppDarkPalette p) {
    final base = createDarkTheme(null);
    final scheme = base.colorScheme.copyWith(
      primary: p.accent,
      onPrimary: p.onAccent,
      primaryContainer: p.selected,
      onPrimaryContainer: p.onSelected,
      secondary: p.accent,
      onSecondary: p.onAccent,
      secondaryContainer: p.selected,
      onSecondaryContainer: p.onSelected,
      tertiary: p.accent,
      onTertiary: p.onAccent,
      surface: p.background,
      surfaceDim: p.background,
      surfaceBright: p.surfaceHighest,
      surfaceContainerLowest: p.background,
      surfaceContainerLow: p.surface,
      surfaceContainer: p.surface,
      surfaceContainerHigh: p.surfaceHigh,
      surfaceContainerHighest: p.surfaceHighest,
      onSurfaceVariant: p.muted,
      outlineVariant: p.outline,
    );
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: p.background,
      canvasColor: p.background,
      iconTheme: base.iconTheme.copyWith(color: p.muted),
      dialogTheme: base.dialogTheme.copyWith(backgroundColor: p.surface),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: p.surface,
        modalBackgroundColor: p.surface,
      ),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: p.background,
        surfaceTintColor: Colors.transparent,
      ),
      popupMenuTheme: _popupMenuTheme(scheme),
      menuTheme: _menuTheme(scheme),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: p.surface,
        selectedColor: p.accent.withValues(alpha: 0.18),
        secondarySelectedColor: p.accent.withValues(alpha: 0.18),
        secondaryLabelStyle: TextStyle(
          color: p.accent,
          fontWeight: FontWeight.w600,
        ),
        checkmarkColor: p.accent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? p.onAccent : p.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.accent
              : p.surfaceHighest,
        ),
      ),
    );
  }

  static ThemeData createDarkTheme(ColorScheme? _) {
    // Keep the official AnimeWitcher accent fixed instead of allowing Android
    // dynamic colors to replace it with a device-specific blue/purple palette.
    var colorScheme = ColorScheme.fromSeed(
      seedColor: animeWitcherAccent,
      brightness: Brightness.dark,
      surface: const Color(0xFF000000),
    );

    // AnimeWitcher uses one gold accent for its interactive theme. Force the
    // key Material roles to that same accent while preserving semantic errors.
    colorScheme = colorScheme.copyWith(
      primary: animeWitcherAccent,
      onPrimary: Colors.black,
      secondary: animeWitcherAccent,
      onSecondary: Colors.black,
      tertiary: animeWitcherAccent,
      onTertiary: Colors.black,
      surface: const Color(0xFF000000),
      // The seeded value is a dim grey that all but disappears against a pure
      // black background. Icons and secondary labels are drawn in it
      // throughout the app, so it is lifted to something legible rather than
      // colouring each of them by hand.
      onSurfaceVariant: darkIconNeutral,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: appFontFamily,
      pageTransitionsTheme: _pageTransitionsTheme,
      brightness: Brightness.dark,
      // An icon that names no colour of its own still has to be visible on
      // black; Material's default leans too dark for this background.
      iconTheme: const IconThemeData(color: darkIconNeutral),
      scaffoldBackgroundColor: const Color(
        0xFF000000,
      ), // Pure Black Background for Screens
      // Dialog Theme (Premium Grey)
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF18181F),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_surfaceRadius),
          side: _hairline(colorScheme),
        ),
        titleTextStyle: _appFont(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: const Color(0xFFF9FAFB),
        ),
      ),

      // Bottom Sheet Theme (Premium Grey)
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: const Color(0xFF18181F),
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: const Color(0xFF18181F),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(_surfaceRadius),
          ),
          side: _hairline(colorScheme),
        ),
      ),

      popupMenuTheme: _popupMenuTheme(colorScheme),
      menuTheme: _menuTheme(colorScheme),

      // Card Theme (Pitch Black for List Items)
      cardTheme: const CardThemeData(
        color: Color(0xFF000000),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),

      // Material 3 Color Scheme
      colorScheme: colorScheme,

      // Typography
      textTheme: ThemeData.dark().textTheme
          .apply(fontFamily: appFontFamily)
          .copyWith(
            displayLarge: _appFont(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: const Color(0xFFF9FAFB),
            ),
            displayMedium: _appFont(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: const Color(0xFFF9FAFB),
            ),
            displaySmall: _appFont(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: const Color(0xFFF9FAFB),
            ),
            headlineMedium: _appFont(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: const Color(0xFFF9FAFB),
            ),
            titleLarge: _appFont(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: const Color(0xFFF9FAFB),
            ),
            titleMedium: _appFont(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: const Color(0xFFF9FAFB),
            ),
            bodyLarge: _appFont(fontSize: 16, color: const Color(0xFFE5E7EB)),
            bodyMedium: _appFont(fontSize: 14, color: const Color(0xFF9CA3AF)),
            bodySmall: _appFont(fontSize: 12, color: const Color(0xFF6B7280)),
            labelLarge: _appFont(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
              color: const Color(0xFFF9FAFB),
            ),
          ),

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: const Color(0xFF000000),
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: _toolbarHeight,
      ),

      // Bottom Navigation
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: const Color(
          0xFF000000,
        ), // Pure Black matches background
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showSelectedLabels: false,
        showUnselectedLabels: false,
        landscapeLayout: BottomNavigationBarLandscapeLayout.spread,
      ),

      // Keep SnackBars visually consistent with the dark application instead
      // of Material's default inverse (light) surface.
      snackBarTheme: snackBarThemeFor(colorScheme),

      // Input Decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF18181F), // Slightly lighter grey for fields
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
      ),

      // Chip Theme — the light theme styles chips explicitly, so the dark
      // theme has to as well or filter chips fall back to Material's default
      // grey and stop reading as part of the gold accent language.
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFF18181F),
        disabledColor: colorScheme.onSurface.withValues(alpha: 0.12),
        selectedColor: colorScheme.primary.withValues(alpha: 0.18),
        secondarySelectedColor: colorScheme.primary.withValues(alpha: 0.18),
        // Semi-bold: at chip size the regular weight read as faint beside
        // the page's other labels.
        labelStyle: TextStyle(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: TextStyle(
          color: colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
        checkmarkColor: colorScheme.primary,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide.none,
        ),
      ),

      // Switch Theme
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary.withValues(alpha: 0.5);
          }
          return null;
        }),
      ),

      // Slider Theme — used by the player's seek/volume bars.
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.primary.withValues(alpha: 0.24),
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.12),
      ),

      // Floating Action Button Theme
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),

      // Ripple / Splash / Highlights — pointer feedback matters far more on
      // desktop, where hover is the primary affordance for "this is tappable".
      splashColor: colorScheme.primary.withValues(alpha: 0.1),
      hoverColor: colorScheme.primary.withValues(alpha: 0.06),
      highlightColor: colorScheme.primary.withValues(alpha: 0.05),

      // Selection Text Theme — keeps the caret/selection gold instead of the
      // default blue that Material picks for dark schemes.
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colorScheme.primary,
        selectionColor: colorScheme.primary.withValues(alpha: 0.3),
        selectionHandleColor: colorScheme.primary,
      ),

      dividerColor: const Color(0xFF22222E),
      dividerTheme: const DividerThemeData(
        thickness: 1,
        space: 1,
        color: Color(0xFF22222E),
      ),
    );
  }

  static ThemeData createLightTheme(ColorScheme? _) {
    final generatedScheme = ColorScheme.fromSeed(
      seedColor: animeWitcherAccent,
      brightness: Brightness.light,
    );
    final colorScheme = generatedScheme.copyWith(
      primary: animeWitcherAccent,
      onPrimary: Colors.black,
      secondary: animeWitcherAccent,
      onSecondary: Colors.black,
      tertiary: animeWitcherAccent,
      onTertiary: Colors.black,
      surface: lightBackground,
      onSurface: lightTextPrimary,
      onSurfaceVariant: lightTextSecondary,
      outline: const Color(0xFFC9BBA6), // Warm sand outline
      outlineVariant: const Color(0xFFD9C9AE), // Soft warm tan outlineVariant
      error: const Color(0xFFBA1A1A),
      onError: Colors.white,
      surfaceContainerLowest: lightSurface,
      surfaceContainerLow: const Color(0xFFF7F3EE),
      surfaceContainer: const Color(0xFFEFEAE2),
      surfaceContainerHigh: lightSurfaceHighlight,
      surfaceContainerHighest: const Color(0xFFE4D9C8),
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: appFontFamily,
      pageTransitionsTheme: _pageTransitionsTheme,
      brightness: Brightness.light,
      scaffoldBackgroundColor: colorScheme.surface,

      // Dialog Theme
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_surfaceRadius),
          side: _hairline(colorScheme),
        ),
        titleTextStyle: _appFont(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),

      // Bottom Sheet Theme
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: colorScheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(_surfaceRadius),
          ),
          side: _hairline(colorScheme),
        ),
      ),

      popupMenuTheme: _popupMenuTheme(colorScheme),
      menuTheme: _menuTheme(colorScheme),

      // Card Theme
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),

      // Material 3 Color Scheme
      colorScheme: colorScheme,

      // Typography
      textTheme: ThemeData.light().textTheme
          .apply(fontFamily: appFontFamily)
          .copyWith(
            displayLarge: _appFont(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
            headlineMedium: _appFont(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
            titleLarge: _appFont(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
            bodyLarge: _appFont(fontSize: 16, color: colorScheme.onSurface),
            bodyMedium: _appFont(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
            bodySmall: _appFont(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
          ),

      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        titleTextStyle: _appFont(
          color: colorScheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        toolbarHeight: _toolbarHeight,
      ),

      // Bottom Navigation
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: colorScheme.surface,
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        showSelectedLabels: false,
        showUnselectedLabels: false,
      ),

      // Input Decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),

      // Chip Theme
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        disabledColor: colorScheme.onSurface.withValues(alpha: 0.12),
        selectedColor: colorScheme.primary.withValues(alpha: 0.15),
        secondarySelectedColor: colorScheme.primary.withValues(alpha: 0.15),
        // Semi-bold: at chip size the regular weight read as faint beside
        // the page's other labels.
        labelStyle: TextStyle(
          color: colorScheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: TextStyle(
          color: colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
        checkmarkColor: colorScheme.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide.none,
        ),
      ),

      // Switch Theme
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary.withValues(alpha: 0.5);
          }
          return null;
        }),
      ),

      // Slider Theme
      sliderTheme: SliderThemeData(
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.primary.withValues(alpha: 0.24),
        thumbColor: colorScheme.primary,
        overlayColor: colorScheme.primary.withValues(alpha: 0.12),
      ),

      // Floating Action Button Theme
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),

      // SnackBar Theme
      snackBarTheme: snackBarThemeFor(colorScheme),

      // Ripple / Splash / Highlights
      splashColor: colorScheme.primary.withValues(alpha: 0.1),
      hoverColor: colorScheme.primary.withValues(alpha: 0.04),
      highlightColor: colorScheme.primary.withValues(alpha: 0.05),

      // Selection Text Theme
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colorScheme.primary,
        selectionColor: colorScheme.primary.withValues(alpha: 0.3),
        selectionHandleColor: colorScheme.primary,
      ),

      dividerColor: colorScheme.outlineVariant,
      dividerTheme: DividerThemeData(
        thickness: 1,
        space: 1,
        color: colorScheme.outlineVariant,
      ),
    );
  }
}

/// The colours of a tinted dark theme: an accent, the surfaces from the page
/// up to the highest card, and the muted text and lines between them.
@immutable
class AppDarkPalette {
  const AppDarkPalette({
    required this.accent,
    required this.onAccent,
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceHighest,
    required this.selected,
    required this.onSelected,
    required this.muted,
    required this.outline,
  });

  final Color accent;
  final Color onAccent;
  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color surfaceHighest;

  /// The fill behind a chosen item, and the text on it.
  final Color selected;
  final Color onSelected;
  final Color muted;
  final Color outline;
}
