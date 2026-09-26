import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../storage/settings_repository.dart';
import '../providers/device_info_provider.dart';
import '../storage/storage_service.dart';
import 'app_theme.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'theme_provider.g.dart';

@Riverpod(keepAlive: true)
class AppThemeMode extends _$AppThemeMode {
  late SettingsRepository _repository;

  @override
  ThemeMode build() {
    _repository = ref.watch(settingsRepositoryProvider);
    final saved = _repository.getThemeMode();
    if (saved == null) {
      final profileAsync = ref.watch(deviceProfileProvider);
      final profile = profileAsync.asData?.value;
      // While the profile is still loading, render dark. Splash + cold-start
      // surfaces should match the dark splash background; a system-themed
      // light flash is the worse failure mode.
      if (profile == null) {
        return ThemeMode.dark;
      }
      if (profile.isTv) {
        return ThemeMode.dark;
      }
      return ThemeMode.system;
    }
    return _getThemeMode(saved);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    await _repository.saveThemeMode(mode.name);
  }

  ThemeMode _getThemeMode(String mode) {
    // Kept for installs from before the theme choice; see [AppThemeStyle].
    switch (mode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }
}

/// The app's themes, as the viewer picks them.
///
/// There is no "follow the system" entry: with more than one dark theme the
/// system's light-or-dark answer no longer says which one to draw.
enum AppThemeStyle {
  /// Black, with the gold accent — the app's original look.
  dark,

  /// The light theme.
  light,

  /// Warm charcoal with an amber accent.
  amber,

  /// True black, for OLED screens.
  amoled,

  /// Deep navy with sky blue.
  ocean,

  /// Pine green with emerald.
  forest,

  /// Dark plum with cherry-blossom pink.
  sakura,

  /// Night indigo with lavender.
  violet,

  /// Near black with crimson.
  crimson;

  static AppThemeStyle? fromName(String? raw) {
    for (final value in AppThemeStyle.values) {
      if (value.name == raw?.trim()) return value;
    }
    return null;
  }

  Brightness get brightness =>
      this == AppThemeStyle.light ? Brightness.light : Brightness.dark;

  ThemeMode get themeMode =>
      this == AppThemeStyle.light ? ThemeMode.light : ThemeMode.dark;

  String label({required bool arabic}) => switch (this) {
    AppThemeStyle.dark => arabic ? 'داكن' : 'Dark',
    AppThemeStyle.light => arabic ? 'فاتح' : 'Light',
    AppThemeStyle.amber => arabic ? 'كهرماني' : 'Amber',
    AppThemeStyle.amoled => arabic ? 'أسود نقي' : 'AMOLED black',
    AppThemeStyle.ocean => arabic ? 'محيطي' : 'Ocean',
    AppThemeStyle.forest => arabic ? 'غابة' : 'Forest',
    AppThemeStyle.sakura => arabic ? 'ساكورا' : 'Sakura',
    AppThemeStyle.violet => arabic ? 'بنفسجي' : 'Violet',
    AppThemeStyle.crimson => arabic ? 'قرمزي' : 'Crimson',
  };

  /// The theme's accent, for a dot beside its name in the pickers.
  Color get swatch => switch (this) {
    AppThemeStyle.dark => AppTheme.animeWitcherAccent,
    AppThemeStyle.light => AppTheme.lightBackground,
    _ => AppTheme.paletteFor(this)!.accent,
  };
}

/// Which theme to draw. Stored on its own; an install from before it reads
/// its old light-or-dark setting instead, with "system" resolved to dark.
final appThemeStyleProvider =
    NotifierProvider<AppThemeStyleNotifier, AppThemeStyle>(
      AppThemeStyleNotifier.new,
    );

class AppThemeStyleNotifier extends Notifier<AppThemeStyle> {
  static const String storageKey = 'app_theme_style';

  @override
  AppThemeStyle build() {
    try {
      final stored = AppThemeStyle.fromName(
        ref.read(storageServiceProvider).getString(storageKey),
      );
      if (stored != null) return stored;
    } catch (_) {
      // Fall through to the older setting.
    }
    return ref.read(appThemeModeProvider) == ThemeMode.light
        ? AppThemeStyle.light
        : AppThemeStyle.dark;
  }

  Future<void> select(AppThemeStyle style) async {
    state = style;
    // The older setting follows, so anything still reading it agrees.
    await ref.read(appThemeModeProvider.notifier).setThemeMode(style.themeMode);
    try {
      await ref.read(storageServiceProvider).setString(storageKey, style.name);
    } catch (_) {
      // Worst case the previous theme comes back next launch.
    }
  }
}
