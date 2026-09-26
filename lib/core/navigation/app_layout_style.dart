/// Where the app's navigation sits.
///
/// Chosen once, on the first launch, from a picker; changeable later in
/// settings, on a desktop window or a tablet: the floating bar, a side rail
/// or a top bar. A phone has no choice to make: it always has the floating
/// bar and, pulled out from the left, the side menu.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/responsive_breakpoints.dart';

import '../storage/storage_service.dart';

enum AppLayoutStyle {
  /// The floating bar along the bottom — the layout the app always had.
  dock,

  /// A narrow column of icons down the side.
  sideRail,

  /// A bar of named pages across the top, over the artwork on home.
  topBar;

  static AppLayoutStyle? fromName(String? raw) {
    for (final value in AppLayoutStyle.values) {
      if (value.name == raw?.trim()) return value;
    }
    return null;
  }

  String label({required bool arabic}) => switch (this) {
    AppLayoutStyle.dock => arabic ? 'الشريط السفلي' : 'Bottom bar',
    AppLayoutStyle.sideRail => arabic ? 'شريط جانبي' : 'Side rail',
    AppLayoutStyle.topBar => arabic ? 'شريط علوي' : 'Top bar',
  };

  String description({required bool arabic}) => switch (this) {
    AppLayoutStyle.dock =>
      arabic
          ? 'الشكل الافتراضي: شريط عائم أسفل الشاشة'
          : 'The default: a floating bar at the bottom',
    AppLayoutStyle.sideRail =>
      arabic
          ? 'أيقونات على جانب الشاشة، والمساحة كلها للمحتوى'
          : 'Icons down the side, the full width for content',
    AppLayoutStyle.topBar =>
      arabic
          ? 'أسماء الصفحات في شريط أعلى الشاشة'
          : 'Named pages in a bar across the top',
  };
}

/// The layouts offered: the three for a desktop or a tablet ([wide]); a
/// phone has only its own.
List<AppLayoutStyle> appLayoutChoices({required bool wide}) => wide
    ? AppLayoutStyle.values
    : const <AppLayoutStyle>[AppLayoutStyle.dock];

/// The style actually drawn: the stored choice when this kind of screen
/// offers it ([isDesktopPlatform] for a desktop or a tablet), the dock
/// otherwise or before anything was chosen.
AppLayoutStyle effectiveAppLayout({
  required AppLayoutStyle? stored,
  required bool isDesktopPlatform,
}) {
  if (stored != null &&
      appLayoutChoices(wide: isDesktopPlatform).contains(stored)) {
    return stored;
  }
  return AppLayoutStyle.dock;
}

/// Whether to put the picker in front of the viewer: a desktop that has
/// never recorded a choice.
bool shouldAskForAppLayout({
  required AppLayoutStyle? stored,
  required bool isDesktopPlatform,
}) {
  return isDesktopPlatform && stored == null;
}

/// The stored choice; null until the viewer has picked one.
final appLayoutStyleProvider =
    NotifierProvider<AppLayoutStyleNotifier, AppLayoutStyle?>(
      AppLayoutStyleNotifier.new,
    );

class AppLayoutStyleNotifier extends Notifier<AppLayoutStyle?> {
  static const String storageKey = 'app_layout_style';

  StorageService get _storage => ref.read(storageServiceProvider);

  @override
  AppLayoutStyle? build() {
    try {
      return AppLayoutStyle.fromName(_storage.getString(storageKey));
    } catch (_) {
      // Unreadable storage asks again rather than keeping the app from
      // drawing its shell.
      return null;
    }
  }

  void select(AppLayoutStyle style) {
    state = style;
    try {
      _storage.setString(storageKey, style.name);
    } catch (_) {
      // Worst case the picker is offered again on the next launch.
    }
  }
}

/// Whether this screen offers the side rail and the top bar: a desktop, or
/// a tablet — a screen whose short side is at least 600 points, which a
/// phone in either orientation is not. A tablet has the width a rail takes
/// and still leaves a comfortable page; a phone does not.
bool appLayoutsAvailable(BuildContext context) {
  if (ResponsiveBreakpoints.isDesktopPlatform()) return true;
  return MediaQuery.sizeOf(context).shortestSide >= 600;
}
